package hxmc.rt.gc;

import hxmc.rt.Str;

// -D hxmc.wasm-gc: Dynamic's comparisons and printing (W.kind), as hxmc.rt.Dyn's
@:keep @:hxmc.wasmgc
class GcDyn {
	@:hxmc.host("hx_dyn_eq") @:hxmc.noGc public static function eq(a:Dynamic, b:Dynamic):Bool {
		var ka = W.kind(a), kb = W.kind(b);
		// (an Int64, with an Int64 or an Int)
		if ((ka == 9 || kb == 9) && (ka == 9 || ka == 1) && (kb == 9 || kb == 1)) return W.unboxI64(a) == W.unboxI64(b);
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) return W.unboxFloat(a) == W.unboxFloat(b);
		if (ka == 3 && kb == 3) return W.unboxBool(a) == W.unboxBool(b);
		if (ka == 4 && kb == 4) return (a : String) == (b : String);
		return same(a, b);
	}

	// the same reference (or both null)
	static inline function same(a:Dynamic, b:Dynamic):Bool
		return W.same(a, b);

	@:hxmc.host("hx_dyn_cmp") @:hxmc.noGc static function cmp(a:Dynamic, b:Dynamic):Int {
		var ka = W.kind(a), kb = W.kind(b);
		if ((ka == 1 || ka == 2) && (kb == 1 || kb == 2)) {
			var x = W.unboxFloat(a), y = W.unboxFloat(b);
			return x < y ? -1 : x > y ? 1 : 0;
		}
		if (ka == 4 && kb == 4) return @:privateAccess Str.cmp(a, b);
		return eq(a, b) ? 0 : -1;
	}

	// a op b on Dynamic values (FnLower.opCode: 0 + 1 - 2 * 3 / 4 % 5 & 6 | 7 ^ 8 << 9 >> 10 >>>)
	@:hxmc.host("hx_dyn_op") static function op(op:Int, a:Dynamic, b:Dynamic):Dynamic {
		var ka = W.kind(a), kb = W.kind(b);
		if (op == 0 && (ka == 4 || kb == 4)) return string(a) + string(b);
		var ints = ka != 0 && kb != 0 && ka != 2 && kb != 2;
		if (op >= 5 || (ints && op != 3)) {
			var x = W.unboxInt(a), y = W.unboxInt(b);
			var r = switch op {
				case 0: x + y;
				case 1: x - y;
				case 2: x * y;
				case 4: x % y;
				case 5: x & y;
				case 6: x | y;
				case 7: x ^ y;
				case 8: x << y;
				case 9: x >> y;
				case 10: x >>> y;
				case _: 0;
			}
			return (r : Dynamic);
		}
		var x = W.unboxFloat(a), y = W.unboxFloat(b);
		var r = switch op {
			case 0: x + y;
			case 1: x - y;
			case 2: x * y;
			case 3: x / y;
			case 4: x % y;
			case _: 0.0;
		}
		return (r : Dynamic);
	}

	// a[i] on a Dynamic: an Array's (null out of range), a NativeArray's (out
	// of bounds as -D hxmc.native-array-outofbounds says for typed access, the
	// default of its storage's kind when silent; an error when it is not
	// defined), null throws "Null Access" (as hxmc.rt.Dyn's), else null
	@:hxmc.host("hx_dyn_aget") static function aget(a:Dynamic, i:Int):Dynamic {
		if (W.kind(a) == 0) throw "Null Access";
		if (Std.isOfType(a, Array)) return W.arrGet(a, i);
		if (W.naKind(a) < 0) return null;
		var n = W.naLen(a);
		if (i < 0 || i >= n) {
			#if (hxmc.native_array_outofbounds == "silent")
			return GcNArray.defaultOf(a);
			#elseif (hxmc.native_array_outofbounds == "throws")
			throw GcNArray.outOfBounds(i, n, null, 0, null, null);
			#else
			throw "Invalid NativeArray index";
			#end
		}
		return W.naGet(a, i);
	}

	@:hxmc.host("hx_dyn_aset") static function aset(a:Dynamic, i:Int, v:Dynamic):Void {
		if (W.kind(a) == 0) throw "Null Access";
		if (Std.isOfType(a, Array)) {
			W.arrSet(a, i, v);
			return;
		}
		if (W.naKind(a) < 0) throw "Invalid array access";
		var n = W.naLen(a);
		if (i < 0 || i >= n) {
			#if (hxmc.native_array_outofbounds == "silent")
			return;
			#elseif (hxmc.native_array_outofbounds == "throws")
			throw GcNArray.outOfBounds(i, n, null, 0, null, null);
			#else
			throw "Invalid NativeArray index";
			#end
		}
		GcNArray.set(a, i, v);
	}

	// (for the generated code's enum comparisons: hxmc.wasmgc.Meta.enumEq)
	@:hxmc.export("gc_dyn_eq") static function dynEqExport(a:Dynamic, b:Dynamic):Bool
		return eq(a, b);

	@:hxmc.host("Std_string") public static function string(v:Dynamic):String
		return switch W.kind(v) {
			case 0: "null";
			case 1: @:privateAccess Str.ofInt(W.unboxInt(v));
			case 2: @:privateAccess Str.ofFloat(W.unboxFloat(v));
			case 3: W.unboxBool(v) ? "true" : "false";
			case 4: (v : String);
			case 6: enumString(v);
			case 7:
				var b = new StringBuf();
				b.addChar("[".code);
				for (i in 0...W.arrLen(v)) {
					if (i > 0) b.addChar(",".code);
					b.add(string(W.arrGet(v, i)));
				}
				b.addChar("]".code);
				b.toString();
			case 8: "<function>";
			case 9: @:privateAccess Str.ofI64(W.unboxI64(v));
			case 10: anonString(v);
			// (the runtime type's name, as hxmc.rt.Dyn's)
			case 11 if (W.naKind(v) >= 0): "hxmc.NativeArray";
			case _: "[object]";
		}

	// an anonymous structure: { a : 1, b : 2 }, its own fields (its layout's,
	// by name), then those added (GcFields, in the order they were added), as
	// hxmc.rt.Dyn.anonToString
	static function anonString(o:Dynamic):String {
		var b = new StringBuf();
		b.addChar("{".code);
		var n = 0;
		var names:Array<String> = W.fieldNames(o);
		if (names != null)
			for (i in 0...names.length) {
				b.add(n++ == 0 ? " " : ", ");
				b.add(names[i]);
				b.add(" : ");
				b.add(string(W.objGet(o, i)));
			}
		var x:GcNative.GcFields = W.anonOverflow(o);
		if (x != null) {
			var i = 0;
			// (the length read again: a toString may add fields)
			while (i < x.names.length) {
				b.add(n++ == 0 ? " " : ", ");
				b.add(x.names[i]);
				b.add(" : ");
				b.add(string(x.values[i]));
				i++;
			}
		}
		b.add(n > 0 ? " }" : "}");
		return b.toString();
	}

	// an enum value: Name(p1,p2), as hxmc.rt.Dyn.stdString
	static function enumString(v:Dynamic):String {
		var b = new StringBuf();
		b.add((W.enumNames(W.enumOf(v)) : Array<String>)[W.enumIndex(v)]);
		var ps = W.enumParams(v);
		if (ps.length > 0) {
			b.addChar("(".code);
			for (i in 0...ps.length) {
				if (i > 0) b.addChar(",".code);
				b.add(string(ps[i]));
			}
			b.addChar(")".code);
		}
		return b.toString();
	}

	@:hxmc.host("hx_std_string") static function stdString(v:Dynamic):String
		return string(v);
}
