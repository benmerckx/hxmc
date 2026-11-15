package hxmc.neko;

import haxe.io.Bytes;

// Neko's values (neko/vm/neko.h): null, Bool, Int and Float are Haxe's own
// (an Int is Neko's int or int32, whichever its value needs), an array is a
// Haxe Array<Dynamic> of fixed length; the rest are the classes below, their
// tag the number $typeof answers.
class Tag {
	public static inline var TNULL = 0;
	public static inline var TINT = 1;
	public static inline var TFLOAT = 2;
	public static inline var TBOOL = 3;
	public static inline var TSTRING = 4;
	public static inline var TOBJECT = 5;
	public static inline var TARRAY = 6;
	public static inline var TFUNCTION = 7;
	public static inline var TABSTRACT = 8;

	public static function of(v:Dynamic):Int {
		if (v == null) return TNULL;
		if (isInt(v)) return TINT;
		if (isFloat(v)) return TFLOAT;
		if (isBool(v)) return TBOOL;
		if (Std.isOfType(v, NVal)) return (v : NVal).tag;
		if (isArray(v)) return TARRAY;
		throw 'neko: a foreign value (kind ${hxmc.Native.typeKind(v)})';
	}

	// (the number boxes tested exactly and inline: a Float of an integer's
	// value is no Int; the classes by Std.isOfType's inline range test)
	public static inline function isInt(v:Dynamic):Bool
		return hxmc.Native.isIntBox(v);

	public static inline function isFloat(v:Dynamic):Bool
		return hxmc.Native.isFloatBox(v);

	public static inline function isBool(v:Dynamic):Bool
		return hxmc.Native.isBoolBox(v);

	public static inline function isArray(v:Dynamic):Bool
		return hxmc.Native.typeKind(v) == 9;

	public static inline function isString(v:Dynamic):Bool
		return Std.isOfType(v, NStr);

	public static inline function isObject(v:Dynamic):Bool
		return Std.isOfType(v, NObj);

	public static inline function isFunction(v:Dynamic):Bool
		return Std.isOfType(v, NFun);

	public static inline function isAbstract(v:Dynamic):Bool
		return Std.isOfType(v, NAbs);

	// 0 null, 1 Int, 2 Float, 3 Bool, 4 another value
	public static inline function kind(v:Dynamic):Int
		return v == null ? 0 : isInt(v) ? 1 : isFloat(v) ? 2 : isBool(v) ? 3 : 4;

	// an Int that does not fit Neko's 31 bits is an int32 (alloc_best_int)
	public static inline function need32(i:Int):Bool
		return ((i + 0x40000000) & 0x80000000) != 0;
}

class NVal {
	public final tag:Int;

	public function new(tag:Int)
		this.tag = tag;
}

// a Neko string: mutable bytes of a fixed length
class NStr extends NVal {
	public var b:Bytes;

	public function new(b:Bytes) {
		super(Tag.TSTRING);
		this.b = b;
	}

	public static inline function of(s:String):NStr
		return new NStr(Bytes.ofString(s));

	public inline function length():Int
		return b.length;

	public inline function toString():String
		return b.toString();
}

// fields sorted by their hash (neko/vm/objtable.h), the prototype: the
// first n slots of ids and vals (their capacity grows by doubling)
class NObj extends NVal {
	static final NO_IDS = new haxe.ds.Vector<Int>(0);
	static final NO_VALS = new haxe.ds.Vector<Dynamic>(0);

	public var ids:haxe.ds.Vector<Int>;
	public var vals:haxe.ds.Vector<Dynamic>;
	public var n = 0;
	public var proto:Null<NObj>;

	public function new(?proto:NObj) {
		super(Tag.TOBJECT);
		ids = NO_IDS;
		vals = NO_VALS;
		this.proto = proto;
	}

	public inline function find(id:Int):Int {
		var min = 0, max = n;
		var found = -1;
		while (min < max) {
			var mid = (min + max) >> 1;
			var c = ids[mid];
			if (c < id) min = mid + 1 else if (c > id) max = mid else {
				found = mid;
				break;
			}
		}
		return found;
	}

	// the field of this object or a prototype, or undefined: `has` tells
	public function get(id:Int):Dynamic {
		var o = this;
		while (o != null) {
			var i = o.find(id);
			if (i >= 0) return o.vals[i];
			o = o.proto;
		}
		return null;
	}

	public function hasOwn(id:Int):Bool
		return find(id) >= 0;

	public function getOwn(id:Int):Dynamic {
		var i = find(id);
		return i >= 0 ? vals[i] : null;
	}

	public function has(id:Int):Bool {
		var o = this;
		while (o != null) {
			if (o.find(id) >= 0) return true;
			o = o.proto;
		}
		return false;
	}

	public function set(id:Int, v:Dynamic):Void {
		var min = 0, max = n;
		while (min < max) {
			var mid = (min + max) >> 1;
			var c = ids[mid];
			if (c < id) min = mid + 1 else if (c > id) max = mid else {
				vals[mid] = v;
				return;
			}
		}
		if (n == ids.length) {
			var cap = n == 0 ? 4 : n * 2;
			var ni = new haxe.ds.Vector<Int>(cap), nv = new haxe.ds.Vector<Dynamic>(cap);
			haxe.ds.Vector.blit(ids, 0, ni, 0, n);
			haxe.ds.Vector.blit(vals, 0, nv, 0, n);
			ids = ni;
			vals = nv;
		}
		// (Vector.blit moves overlapping slots as memmove does)
		if (min < n) {
			haxe.ds.Vector.blit(ids, min, ids, min + 1, n - min);
			haxe.ds.Vector.blit(vals, min, vals, min + 1, n - min);
		}
		ids[min] = id;
		vals[min] = v;
		n++;
	}

	public function remove(id:Int):Bool {
		var i = find(id);
		if (i < 0) return false;
		if (i < n - 1) {
			haxe.ds.Vector.blit(ids, i + 1, ids, i, n - 1 - i);
			haxe.ds.Vector.blit(vals, i + 1, vals, i, n - 1 - i);
		}
		n--;
		vals[n] = null;
		return true;
	}

	// $new(o): o's fields copied, o's prototype
	public function copy():NObj {
		var o = new NObj(proto);
		if (n > 0) {
			o.ids = new haxe.ds.Vector<Int>(n);
			o.vals = new haxe.ds.Vector<Dynamic>(n);
			haxe.ds.Vector.blit(ids, 0, o.ids, 0, n);
			haxe.ds.Vector.blit(vals, 0, o.vals, 0, n);
			o.n = n;
		}
		return o;
	}
}

// (the arguments: a Vector, one allocation of their number)
typedef Prim = (vm:VM, args:haxe.ds.Vector<Dynamic>) -> Dynamic;

// a function of a module's code (prim == null) or a primitive; nargs -1: any
class NFun extends NVal {
	public var nargs:Int;
	public var env:Dynamic;
	public var module:Null<Module>;
	public var addr:Int;
	public var prim:Null<Prim>;
	public var name:String;

	public function new(nargs:Int, env:Dynamic, module:Module, addr:Int, prim:Prim, name:String) {
		super(Tag.TFUNCTION);
		this.nargs = nargs;
		this.env = env;
		this.module = module;
		this.addr = addr;
		this.prim = prim;
		this.name = name;
	}

	public static inline function primitive(name:String, nargs:Int, f:Prim, ?env:Dynamic):NFun
		return new NFun(nargs, env, null, 0, f, name);
}

// an abstract value: its kind and data
class NAbs extends NVal {
	public var kind:String;
	public var data:Dynamic;

	public function new(kind:String, data:Dynamic) {
		super(Tag.TABSTRACT);
		this.kind = kind;
		this.data = data;
	}
}

// what $throw and a failing operation raise
class NekoError {
	public var value:Dynamic;
	// the positions it went through, innermost first
	public var stack:Null<Array<Dynamic>>;
	// the depth it was thrown at
	public var depth = 0;

	public function new(v:Dynamic)
		this.value = v;

	public function toString():String
		return Std.string(value);
}
