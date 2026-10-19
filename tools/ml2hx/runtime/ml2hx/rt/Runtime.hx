package ml2hx.rt;


// Primitives the emitter calls: OCaml's structural equality, comparison and
// hashing over the representations of the README, checked accesses, and the
// matching helpers for extensible types.
class Runtime {
	// ---------------------------------------------------------------- ints
	public static function div(a:Int, b:Int):Int {
		if (b == 0) throw DivisionByZero.instance;
		var q = a / b;
		return Std.int(q);
	}
	public static function mod(a:Int, b:Int):Int {
		if (b == 0) throw DivisionByZero.instance;
		return a % b;
	}
	public static inline function compareInt(a:Int, b:Int):Int return a < b ? -1 : a > b ? 1 : 0;
	public static inline function compareBool(a:Bool, b:Bool):Int return (a ? 1 : 0) - (b ? 1 : 0);
	public static function compareString(a:String, b:String):Int return a < b ? -1 : a > b ? 1 : 0;

	// ---------------------------------------------------------------- checked accesses
	public static function stringGet(s:String, i:Int):Int {
		if (i < 0 || i >= s.length) throw new InvalidArgument("index out of bounds");
		return StringTools.fastCodeAt(s, i);
	}
	// a byte of a string or of bytes (OCaml code may view one as the other)
	public static function anyByteGet(s:Dynamic, i:Int):Int {
		if (Std.isOfType(s, String)) return stringGet(s, i);
		return bytesGet(s, i);
	}
	public static function bytesGet(b:haxe.io.Bytes, i:Int):Int {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
		return b.get(i);
	}
	public static function bytesSet(b:haxe.io.Bytes, i:Int, c:Int):Unit {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
		b.set(i, c);
		return Unit.value;
	}
	public static function arrayGet<T>(a:Array<T>, i:Int):T {
		if (i < 0 || i >= a.length) throw new InvalidArgument("index out of bounds");
		return a[i];
	}
	public static function arraySet<T>(a:Array<T>, i:Int, v:T):Unit {
		if (i < 0 || i >= a.length) throw new InvalidArgument("index out of bounds");
		a[i] = v;
		return Unit.value;
	}

	// ---------------------------------------------------------------- extensible types
	public static inline function isInstance<T>(v:Any, c:Class<T>):Bool return Std.isOfType(v, c);
	// Obj.magic of an int to a variant: its constant constructor of that rank
	// (OCaml numbers the constant constructors apart from the others), from
	// the variant's array of them (the literals: hxmc's Type.allEnums makes
	// new values, not == to them)
	public static function constantCtor(all:Array<Any>, i:Int):Dynamic {
		if (i < 0 || i >= all.length) throw new Failure("Obj.magic: no constant constructor " + i);
		return all[i];
	}
	// The result of a function returning Obj.magic's 'a, seen as an int: a
	// constant constructor as its rank (OCaml's immediate), an int as itself
	public static function magicInt(v:Dynamic):Int63 {
		if (Reflect.isEnumValue(v)) {
			var i = Poly.immediateOf(v);
			if (i == null) throw new InvalidArgument("Obj.magic: a constructor with arguments as an int");
			return Int63.ofInt64(i);
		}
		return v;
	}
	// ... seen as a variant: an int as the constant constructor of its rank
	public static function magicVariant(all:Array<Any>, v:Dynamic):Dynamic
		return haxe.Int64.isInt64(v) ? constantCtor(all, (v : Int63).toInt()) : v;
	// o#m with fewer arguments of a staged method: its getter's closure (the
	// method's body run now), or null (no getter: the caller's closure)
	public static function methodValue(o:Dynamic, getter:String):Dynamic {
		var g = Reflect.field(o, getter);
		return g == null ? null : Reflect.callMethod(o, g, []);
	}
	// Obj.magic between two type variables: a constant constructor as its rank
	// (OCaml's immediate); any other value as itself
	public static function magicImmediate(v:Dynamic):Dynamic {
		if (Reflect.isEnumValue(v)) {
			var i = Poly.immediateOf(v);
			if (i != null) return Int63.ofInt64(i);
		}
		return v;
	}
	// Oo.copy: a shallow copy of an object (its fields; no constructor runs)
	public static function objCopy<T>(o:T):T {
		var c = Type.getClass(o);
		if (c == null) return Reflect.copy(o);
		var r = Type.createEmptyInstance(c);
		for (f in Reflect.fields(o)) Reflect.setField(r, f, Reflect.field(o, f));
		return r;
	}
	// A constructor value with an inline record: the record knows it (C r is it).
	public static inline function owned<E>(r:{var ml2hxOwner:Any;}, e:E):E { r.ml2hxOwner = e; return e; }
	public static function downcast<T>(v:Any, c:Class<T>):MlOption<T> return Std.isOfType(v, c) ? Some(cast v) : None;

	// ---------------------------------------------------------------- structural operations
	public static inline function equal(a:Dynamic, b:Dynamic):Bool return Poly.equal(a, b);
	public static inline function compare(a:Dynamic, b:Dynamic):Int return Poly.compare(a, b);
	public static inline function hash(v:Dynamic):Int return Poly.hashParam(10, 100, 0, v);
}
