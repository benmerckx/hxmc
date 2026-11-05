package hxmc.java;

import hxmc.unsafe.*;

// A Java array held by Haxe without copying (docs/interop.md, "Java
// (JNI)"): a Java object whose JNI type is "[" and its element's ([I for
// JavaArray<Int>, [Ljava/lang/String; for JavaArray<String>). An Array,
// Bytes or String parameter or result of a Java method is copied at the
// call; a JavaArray is the array itself, Java's changes and Haxe's seen by
// both.
@:access(hxmc.rt.JniKind)
abstract JavaArray<T>(Dynamic) {
	public var length(get, never):Int;

	inline function get_length():Int
		return Impl.length(this);

	// new arrays of a primitive type, of objects of a class (java.lang.String)
	public static inline function ofInts(n:Int):JavaArray<Int>
		return cast Impl.alloc(5, n, null);

	public static inline function ofBytes(n:Int):JavaArray<UInt8>
		return cast Impl.alloc(2, n, null);

	public static inline function ofDoubles(n:Int):JavaArray<Float>
		return cast Impl.alloc(8, n, null);

	public static inline function ofObjects<E>(n:Int, className:String):JavaArray<E>
		return cast Impl.alloc(0, n, StringTools.replace(className, ".", "/"));

	// an object array's element (Dynamic's conversions: a String, a number, a Java object)
	public inline function get(i:Int):T
		return Impl.get(this, i);

	public inline function set(i:Int, v:T):Void
		Impl.set(this, i, v);

	// f(address, length) with a primitive array's elements in place
	// (GetPrimitiveArrayCritical): no Java call and no waiting for a Java
	// thread until f returns (the JVM may hold its collector meanwhile); f
	// may allocate (the runtime makes no JNI call meanwhile); a JVM that
	// copies writes f's changes back after it
	public inline function critical(f:(address:Ptr, length:Int) -> Void):Void
		Impl.critical(this, f);

	// the elements [pos, pos + n) of a primitive array (type code t: 1
	// boolean, 2 byte, 3 char, 4 short, 5 int, 6 long, 7 float, 8 double)
	// copied to or from memory at p (Get/Set<Type>ArrayRegion)
	public inline function getRegion(t:Int, pos:Int, n:Int, p:Ptr):Void
		Impl.region(this, t, pos, n, p, false);

	public inline function setRegion(t:Int, pos:Int, n:Int, p:Ptr):Void
		Impl.region(this, t, pos, n, p, true);
}

// (JniKind's, where there is JNI; elsewhere a throw)
@:access(hxmc.java.JavaException) @:access(hxmc.rt.JniKind)
private class Impl {
	static function check()
		if (!JavaException.available()) JavaException.unavailable();

	public static function length(a:Dynamic):Int {
		check();
		return JavaException.available() ? hxmc.rt.JniKind.arrayLength(a) : 0;
	}

	public static function alloc(t:Int, n:Int, cls:String):Dynamic {
		check();
		return JavaException.available() ? hxmc.rt.JniKind.arrayNew(t, n, cls) : null;
	}

	public static function get(a:Dynamic, i:Int):Dynamic {
		check();
		return JavaException.available() ? hxmc.rt.JniKind.arrayGet(a, i) : null;
	}

	public static function set(a:Dynamic, i:Int, v:Dynamic):Void {
		check();
		if (JavaException.available()) hxmc.rt.JniKind.arraySet(a, i, v);
	}

	public static function critical(a:Dynamic, f:(Ptr, Int) -> Void):Void {
		check();
		if (JavaException.available()) hxmc.rt.JniKind.arrayCritical(a, f);
	}

	public static function region(a:Dynamic, t:Int, pos:Int, n:Int, p:Ptr, write:Bool):Void {
		check();
		if (JavaException.available()) hxmc.rt.JniKind.arrayRegion(a, t, pos, n, p, write);
	}
}
