package hxmc.rt;

import hxmc.rt.Types.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Whether the code running now is macro code (-D hxmc.macros=mir): it sees
// what Eval shows of its values where what a macro generates depends on it
// (tests compare a type's Std.string): Std.string as Eval prints,
// Reflect.fields in Eval's order. Maps keep hxmc's order (docs/hxmc.md,
// "Macros on the Mir interpreter"). The compiler's own code, also when a
// macro calls its API, keeps hxmc's. MirMacros switches it; only the
// programs that can run such code read it (a Mir host, Mem.mirHost, and
// the code compiled for it: -D hxmc.interp, the macro context).
@:access(hxmc.rt.Dyn)
class EvalCompat {
	public static var on = false;

	// how Std.string prints the compiler's own values that macro code has
	// (a position: EvalPrinting's #pos(...)), null for the others
	public static var special:Null<Dynamic->Null<String>> = null;

	// the names Eval gives the classes of the compiler's own values (a position:
	// haxe.macro.Position), by their names (Type.getClassName)
	public static var classNames:Null<Map<String, String>> = null;

	// ---- Std.string: EvalPrinting.s_value, without indentation (Eval's print depth: 5)

	static inline var MAX_DEPTH = 5;

	public static function string(v:Dynamic, depth:Int):String {
		if (depth > MAX_DEPTH) return "<...>";
		if (Str.isNull(v)) return "null";
		var t = tindex(v);
		switch t {
			case T_STRING | T_BOXINT | T_BOXFLOAT | T_BOXI64 | T_BOXBOOL:
				return own(v);
			case T_TYPEOBJ:
				var d = described(v);
				var enum_ = d >= T_FIRST && tk(ty(d)) == TK_ENUM;
				return (enum_ ? "Enum<" : "Class<") + own(v) + ">";
			case T_ARRAY:
				var a:Array<Dynamic> = v;
				var b = new StringBuf();
				b.addChar("[".code);
				for (i in 0...a.length) {
					if (i > 0) b.addChar(",".code);
					b.add(string(a[i], depth + 1));
				}
				b.addChar("]".code);
				return b.toString();
			case _:
		}
		if (t < T_FIRST) return own(v);
		var ty = ty(t);
		switch tk(ty) {
			case TK_CTOR:
				var np = slotCount(ty);
				if (np == 0) return Str.ofAscii(name(ty));
				var b = new StringBuf();
				b.add(Str.ofAscii(name(ty)));
				b.addChar("(".code);
				for (i in 0...np) {
					if (i > 0) b.addChar(",".code);
					b.add(string(Dyn.ctorValue(v, ty, i), depth + 1));
				}
				b.addChar(")".code);
				return b.toString();
			case TK_CLASS:
				if (Dyn.fidToString == 0) Dyn.fidToString = Dyn.fidFind("toString") + 1;
				var f = Dyn.fidToString - 1;
				if (f >= 0) {
					var m = Dyn.findMethod(ty, f);
					if (!m.isNull()) return string(Mem.callRef1(mFn(m), v), depth + 1);
				}
				if (special != null) {
					var s = special(v);
					if (s != null) return s;
				}
				return Str.ofAscii(name(ty));
			case TK_ANON:
				var ts:Dynamic = Reflect.field(v, "toString");
				if (Reflect.isFunction(ts)) return string(Reflect.callMethod(v, ts, []), depth + 1);
				return anon(v, depth + 1);
			case TK_CLOSURE:
				return "#fun";
			case TK_BOUND:
				return "#closure";
			case _:
				return own(v);
		}
	}

	// hxmc's own Std.string
	static function own(v:Dynamic):String {
		on = false;
		var s = Dyn.stdString(v);
		on = true;
		return s;
	}

	// fields in Eval's order (Reflect.fields, a structure printed): by their
	// names' OCaml hashes, ascending (those added at run time too)
	public static function fields(names:Array<String>):Array<String> {
		var hashes = [for (n in names) hash(n)];
		var order = [for (i in 0...names.length) i];
		order.sort((a, b) -> hashes[a] - hashes[b]);
		return [for (i in order) names[i]];
	}

	static function anon(o:Dynamic, depth:Int):String {
		var names = Reflect.fields(o);
		var b = new StringBuf();
		b.addChar("{".code);
		for (k in 0...names.length) {
			if (k > 0) b.add(", ");
			var n = names[k];
			b.add(n);
			b.add(": ");
			b.add(string(Reflect.field(o, n), depth));
		}
		b.addChar("}".code);
		return b.toString();
	}

	// OCaml's Hashtbl.hash of a string: caml_hash's MurmurHash3 over the UTF-8
	// bytes, masked to 30 bits (Eval's field names: EvalHash.camlHashString)
	public static function hash(s:String):Int {
		var b = haxe.io.Bytes.ofString(s);
		var len = b.length;
		var h = 0;
		var i = 0;
		while (i + 4 <= len) {
			h = mix(h, b.get(i) | (b.get(i + 1) << 8) | (b.get(i + 2) << 16) | (b.get(i + 3) << 24));
			i += 4;
		}
		switch len & 3 {
			case 3: h = mix(h, (b.get(i + 2) << 16) | (b.get(i + 1) << 8) | b.get(i));
			case 2: h = mix(h, (b.get(i + 1) << 8) | b.get(i));
			case 1: h = mix(h, b.get(i));
			case _:
		}
		h ^= len;
		h ^= h >>> 16;
		h = h * 0x85ebca6b;
		h ^= h >>> 13;
		h = h * 0xc2b2ae35;
		h ^= h >>> 16;
		return h & 0x3FFFFFFF;
	}

	static inline function rotl(x:Int, n:Int):Int
		return (x << n) | (x >>> (32 - n));

	static inline function mix(h:Int, d:Int):Int {
		d = d * 0xcc9e2d51;
		d = rotl(d, 15);
		d = d * 0x1b873593;
		h ^= d;
		h = rotl(h, 13);
		return h * 5 + 0xe6546b64;
	}
}
