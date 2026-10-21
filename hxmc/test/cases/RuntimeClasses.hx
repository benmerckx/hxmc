// The runtime's classes as values (upstream's unit tests TestSerialize,
// TestCopy, TestType): a Bytes had no class (Type.typeof was TUnknown, so
// haxe.Serializer could not write it and haxe.runtime.Copy failed); and
// Type.getSuperClass of a class without one was the root every class
// extends, not null.
class Base {
	public function new() {}
}

class Sub extends Base {}

class RuntimeClasses {
	static function main() {
		var b = haxe.io.Bytes.ofString("foo");
		Sys.println(Type.getClass(b) == haxe.io.Bytes);
		Sys.println(Type.typeof(b).match(TClass(_)));
		Sys.println(Type.getClassName(Type.getClass(b)) + " " + Type.getClassName(haxe.io.Bytes));
		Sys.println(Type.resolveClass("haxe.io.Bytes") == haxe.io.Bytes);
		var u:haxe.io.Bytes = haxe.Unserializer.run(haxe.Serializer.run(b));
		Sys.println(haxe.Serializer.run(b) + " " + u.toString());
		var c = haxe.runtime.Copy.copy(b);
		Sys.println((c != b) + " " + c.getString(0, 3));
		Sys.println((Type.getSuperClass(Base) == null) + " " + (Type.getSuperClass(Sub) == Base) + " " + (Type.getSuperClass(RuntimeClasses) == null));
	}
}
