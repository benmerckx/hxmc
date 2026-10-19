package hxmc.rt.gc;

// -D hxmc.wasm-gc: reflection (hxmc.Native: Type, Reflect, the maps), as
// hxmc.rt.Dyn's, over the tables and functions of hxmc.wasmgc.Meta (W)
@:keep @:hxmc.wasmgc
class GcNative {
	public static function refEq(a:Dynamic, b:Dynamic):Bool
		return W.same(a, b);

	// 0 null, 1 Int, 2 Float, 3 Bool, 4 anonymous object, 5 function, 6 class
	// instance, 7 enum value, 8 String, 9 Array, 10 a type object, 11 other
	public static function typeKind(v:Dynamic):Int
		return switch W.kind(v) {
			case 0: 0;
			case 1: 1;
			case 2: 2;
			case 3: 3;
			case 4: 8;
			case 5: 6;
			case 6: 7;
			case 7: 9;
			case 8: 5;
			case 10: 4;
			case 12: 10;
			case _: 11;
		}

	public static function isInt64(v:Dynamic):Bool
		return W.kind(v) == 9;

	public static function getClass(v:Dynamic):Dynamic
		return switch W.kind(v) {
			case 4: String;
			case 7: Array;
			case 5: W.classOf(v);
			case _: null;
		}

	public static function getEnum(v:Dynamic):Dynamic
		return W.kind(v) == 6 ? W.enumOf(v) : null;

	// Std.isOfType with a type known at run time only (a literal type is tested
	// inline: hxmc.wasmgc.FuncGen.typeTest), as hxmc.rt.Dyn.is
	@:hxmc.export("gc_is") static function isOfType(v:Dynamic, t:Dynamic):Bool {
		if (W.isNull(v) || W.isNull(t) || !W.isType(t)) return false;
		return switch W.typeKind(t) {
			case 0: W.instOf(v, W.typeId(t));
			case 1: W.kind(v) == 6 && W.typeId(W.enumOf(v)) == W.typeId(t);
			case _:
				switch W.typeName(t) {
					case "Dynamic": true;
					case "Int": isInt(v);
					case "Float": W.kind(v) == 1 || W.kind(v) == 2;
					case "Bool": W.kind(v) == 3;
					case "String": W.kind(v) == 4;
					case "Array": W.kind(v) == 7;
					case "hxmc_NativeArray": W.naKind(v) >= 0;
					case _: false;
				}
		}
	}

	// an Int, or a Float of an Int's value (Std.isOfType(v, Int), as hxmc.rt.Dyn.is)
	@:hxmc.export("gc_is_int") static function isInt(v:Dynamic):Bool {
		var k = W.kind(v);
		if (k == 1) return true;
		if (k != 2) return false;
		var f = W.unboxFloat(v);
		return f == Math.ffloor(f) && Math.abs(f) < 2147483648.0;
	}

	public static function superClass(c:Dynamic):Dynamic
		throw "Type.getSuperClass: not supported by -D hxmc.wasm-gc yet";

	public static function typeName(t:Dynamic):String
		return W.typeName(t);

	public static function resolveType(n:String):Dynamic {
		var i = 0;
		while (true) {
			var t = W.typeAt(i++);
			if (t == null) break;
			if (W.typeName(t) == n) return t;
		}
		return n == "String" ? String : null;
	}

	public static function createEmpty(c:Dynamic):Dynamic
		return W.createEmpty(c);

	public static function enumCtorNames(e:Dynamic):Array<String> {
		if (!W.isType(e) || W.typeKind(e) != 1) return null;
		return (W.enumNames(e) : Array<String>).copy();
	}

	public static function enumCreate(e:Dynamic, index:Int, params:Array<Dynamic>):Dynamic {
		var names:Array<String> = W.enumNames(e);
		if (index < 0 || index >= names.length) throw "Invalid enum constructor";
		return W.enumCreate(e, index, params == null ? [] : params);
	}

	public static function enumIndex(v:Dynamic):Int
		return W.enumIndex(v);

	public static function enumCtorName(v:Dynamic):String
		return (W.enumNames(W.enumOf(v)) : Array<String>)[W.enumIndex(v)];

	public static function enumParams(v:Dynamic):Array<Dynamic>
		return W.enumParams(v);

	public static function enumEq(a:Dynamic, b:Dynamic):Bool
		return W.enumEq(a, b);

	// ---- fields (a class instance's or an anonymous structure's, then those added: GcFields)

	// the index of the name among the names, -1: by reference first (the
	// program's names are its literals, one string each), then by content
	public static function find(names:Array<String>, name:String):Int {
		for (i in 0...names.length)
			if (W.same(names[i], name)) return i;
		for (i in 0...names.length)
			if (names[i] == name) return i;
		return -1;
	}

	static function extra(o:Dynamic, make:Bool):Null<GcFields> {
		if (W.kind(o) != 10) return null;
		var x:GcFields = W.anonOverflow(o);
		if (x == null && make) {
			x = new GcFields();
			W.setAnonOverflow(o, x);
		}
		return x;
	}

	// a structural call the generated code finds no method for (Helpers.anonCall,
	// FuncGen: an object of no class): an Array's or a String's method (as
	// hxmc.rt.Dyn.callBuiltin: Iterable<T>'s iterator()), else a closure field
	@:hxmc.export("gc_anon_call") static function anonCall(o:Dynamic, name:String, args:Array<Dynamic>):Dynamic {
		var k = W.kind(o);
		if (k != 4 && k != 7) return W.dynCall(getField(o, name), args);
		var a0:Dynamic = args.length > 0 ? args[0] : null, a1:Dynamic = args.length > 1 ? args[1] : null;
		if (k == 4) {
			var s:String = o;
			return switch name {
				case "charAt": s.charAt(a0);
				case "charCodeAt": s.charCodeAt(a0);
				case "indexOf": s.indexOf(a0, a1);
				case "lastIndexOf": s.lastIndexOf(a0, a1);
				case "substr": s.substr(a0, a1);
				case "substring": s.substring(a0, a1);
				case "toLowerCase": s.toLowerCase();
				case "toUpperCase": s.toUpperCase();
				case "toString": s;
				case "split": s.split(a0);
				case _: throw "String has no method " + name;
			}
		}
		var a:Array<Dynamic> = o;
		return switch name {
			case "iterator": new haxe.iterators.ArrayIterator(a);
			case "keyValueIterator": new haxe.iterators.ArrayKeyValueIterator(a);
			case "join": a.join(a0);
			case "push": a.push(a0);
			case "pop": a.pop();
			case "shift": a.shift();
			case "copy": a.copy();
			case "concat": a.concat(a0);
			case "indexOf": a.indexOf(a0, a1);
			case "lastIndexOf": a.lastIndexOf(a0, a1);
			case "contains": a.contains(a0);
			case "remove": a.remove(a0);
			case "insert": a.insert(a0, a1); null;
			case "unshift": a.unshift(a0); null;
			case "reverse": a.reverse(); null;
			case "resize": a.resize(a0); null;
			case "slice": a.slice(a0, a1);
			case "splice": a.splice(a0, a1);
			case "toString": a.toString();
			case "sort": a.sort(a0); null;
			case "filter": a.filter(a0);
			case "map": a.map(a0);
			case _: throw "Array has no method " + name;
		}
	}

	// ---- statics reached through a class value (hxmc.ir.Lower.reflectStatics), by its index

	static var classIndices:Null<Map<Int, Int>>;

	// the index (typeAt's) of the class of a class value, -1 for anything else
	static function classIndex(o:Dynamic):Int {
		if (W.kind(o) != 12 || W.typeKind(o) != 0) return -1;
		if (classIndices == null) {
			classIndices = new Map();
			var i = 0;
			while (true) {
				var t = W.typeAt(i);
				if (t == null || W.typeKind(t) != 0) break;
				classIndices.set(W.typeId(t), i++);
			}
		}
		var i = classIndices.get(W.typeId(o));
		return i == null ? -1 : i;
	}

	// the index of a class value's static of the name (W.staticNames), -1
	static function staticIndex(ci:Int, name:String):Int {
		var names = W.staticNames(ci);
		return names == null ? -1 : find(names, name);
	}

	public static function getField(o:Dynamic, name:String):Dynamic {
		// (an Array's or a String's length: structural access)
		var k = W.kind(o);
		if (k == 4 || k == 7) return name == "length" ? (k == 4 ? (o : String).length : (o : Array<Dynamic>).length) : null;
		var ci = classIndex(o);
		if (ci >= 0) {
			var i = staticIndex(ci, name);
			return i < 0 ? null : W.staticGet(ci, i);
		}
		var names:Array<String> = W.fieldNames(o);
		if (names != null) {
			var i = find(names, name);
			if (i >= 0) return W.objGet(o, i);
		}
		var x = extra(o, false);
		return x == null ? null : x.get(name);
	}

	public static function setField(o:Dynamic, name:String, v:Dynamic):Void {
		var ci = classIndex(o);
		if (ci >= 0) {
			var i = staticIndex(ci, name);
			if (i >= 0 && !W.staticSet(ci, i, v)) throw "Cannot rebind this method";
			return;
		}
		var names:Array<String> = W.fieldNames(o);
		if (names != null) {
			var i = find(names, name);
			if (i >= 0) {
				W.objSet(o, i, v);
				return;
			}
		}
		var x = extra(o, true);
		if (x != null) x.set(name, v);
	}

	public static function hasField(o:Dynamic, name:String):Bool {
		var ci = classIndex(o);
		if (ci >= 0) return staticIndex(ci, name) >= 0;
		var names:Array<String> = W.fieldNames(o);
		if (names != null && find(names, name) >= 0) return true;
		var x = extra(o, false);
		return x != null && find(x.names, name) >= 0;
	}

	public static function fields(o:Dynamic):Array<String> {
		var ci = classIndex(o);
		var names:Array<String> = ci >= 0 ? W.staticNames(ci) : W.fieldNames(o);
		var r = names == null ? [] : names.copy();
		var x = extra(o, false);
		if (x != null)
			for (n in x.names)
				r.push(n);
		return r;
	}

	public static function deleteField(o:Dynamic, name:String):Bool {
		var x = extra(o, false);
		if (x == null) return false;
		var i = find(x.names, name);
		if (i < 0) return false;
		x.names.splice(i, 1);
		x.values.splice(i, 1);
		return true;
	}

	public static function instanceFields(c:Dynamic):Array<String>
		throw "Type.getInstanceFields: not supported by -D hxmc.wasm-gc yet";

	public static function callMethod(f:Dynamic, args:Array<Dynamic>):Dynamic
		return W.dynCall(f, args);

	// (as hxmc.rt.Dyn's: a class instance or an anonymous structure copied, with
	// its added fields, any other value itself)
	public static function copyObject(o:Dynamic):Dynamic {
		var k = W.kind(o);
		if (k != 5 && k != 10) return o;
		var c = W.objCopy(o);
		var x = extra(o, false);
		if (x != null) {
			var y = new GcFields();
			for (i in 0...x.names.length) {
				y.names.push(x.names[i]);
				y.values.push(x.values[i]);
			}
			W.setAnonOverflow(c, y);
		}
		return c;
	}

	public static function compareMethods(a:Dynamic, b:Dynamic):Bool
		return W.same(a, b);

	public static function compare(a:Dynamic, b:Dynamic):Int
		return @:privateAccess GcDyn.cmp(a, b);

	// (WasmGC objects have no address: class instances and anonymous structures
	// get a hash, stored in them, the first time; other values 0)
	public static function objHash(o:Dynamic):Int
		return W.objHash(o);

	// ---- Dynamic access (o.name on a Dynamic)

	@:hxmc.host("hx_dyn_get") static function dynGet(o:Dynamic, name:String):Dynamic {
		// (a String's, an Array's, a NativeArray's length, as hxmc.rt.Dyn's)
		if (name.length == 6 && name == "length")
			switch W.kind(o) {
				case 4: return (o : String).length;
				case 7: return W.arrLen(o);
				case 11 if (W.naKind(o) >= 0): return W.naLen(o);
				case _:
			}
		return getField(o, name);
	}

	@:hxmc.host("hx_dyn_set") static function dynSet(o:Dynamic, name:String, v:Dynamic):Void
		setField(o, name, v);

	@:hxmc.host("hx_dyn_call_field") static function dynCallField(o:Dynamic, name:String, args:Array<Dynamic>):Dynamic
		return anonCall(o, name, args == null ? [] : args.copy());

	// ---- structural access the generated code does not know the layout of (hxmc.wasmgc.FuncGen)

	@:hxmc.export("gc_anon_get") static function anonGet(o:Dynamic, name:String):Dynamic
		return getField(o, name);

	@:hxmc.export("gc_anon_set") static function anonSet(o:Dynamic, name:String, v:Dynamic):Void
		setField(o, name, v);
}

// the fields added to an anonymous structure (Reflect.setField of a name its layout lacks)
@:hxmc.wasmgc
class GcFields {
	public final names:Array<String> = [];
	public final values:Array<Dynamic> = [];

	public function new() {}

	public function get(name:String):Dynamic {
		var i = GcNative.find(names, name);
		return i < 0 ? null : values[i];
	}

	public function set(name:String, v:Dynamic) {
		var i = GcNative.find(names, name);
		if (i < 0) {
			names.push(name);
			values.push(v);
		} else values[i] = v;
	}
}
