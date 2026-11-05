package hxmc.java;

// Operations on Java values (docs/interop.md, "Java (JNI)"): a Java object
// is a Haxe reference (a box: one per object while Haxe holds it, so == is
// identity), a Haxe object implementing a Java interface is itself. Where
// there is no JNI (Windows, WebAssembly) each throws.
@:access(hxmc.java.JavaException) @:access(hxmc.rt.JniKind)
class Java {
	// whether a and b are one Java object (IsSameObject)
	public static function same(a:Dynamic, b:Dynamic):Bool {
		if (!JavaException.available()) JavaException.unavailable();
		return JavaException.available() && hxmc.rt.JniKind.same2(a, b);
	}

	// whether v is an instance of the Java class `name` (java.lang.Number)
	public static function isInstance(v:Dynamic, name:String):Bool {
		if (!JavaException.available()) JavaException.unavailable();
		return JavaException.available() && hxmc.rt.JniKind.instanceOf(v, StringTools.replace(name, ".", "/"));
	}

	// v's toString (java.lang.Object's); "null" for null
	public static function toString(v:Dynamic):String {
		if (!JavaException.available()) JavaException.unavailable();
		return JavaException.available() ? hxmc.rt.JniKind.toString(v) : null;
	}

	// v (a Java object's box) gives up its global reference now, rather than
	// when the collector finds it dead; using it afterwards throws
	public static function detach(v:Dynamic):Void {
		if (!JavaException.available()) JavaException.unavailable();
		if (JavaException.available()) hxmc.rt.JniKind.detach(v);
	}

	// the proxies Java holds of a Haxe object implementing Java interfaces
	// (a diagnostic: while it is above 0 the object is kept)
	public static function proxies(v:Dynamic):Int
		return JavaException.available() ? hxmc.rt.JniKind.proxies(v) : 0;
}
