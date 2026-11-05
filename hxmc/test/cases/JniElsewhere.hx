import hxmc.java.*;

// Java without a JVM (docs/interop.md, "Java (JNI)"): code using it
// compiles for every target, and each operation throws a JavaException
// until a JVM is there (hxmc.java.Jvm.create, onLoad, useActivity), or
// always where there is no JNI (Windows, WebAssembly): a call, a field, a
// constructor, Java's functions, a Haxe object passed to Java; a Haxe
// class implementing a Java interface is a Haxe class to Haxe.
@:hxmc.java("java.lang.Runnable") extern interface Runnable {
	function run():Void;
}

@:hxmc.java("jnitest.Nowhere") extern class Nowhere {
	static var count:Int;
	var name:String;
	function new(s:String);
	static function add(a:Int, b:Int):Int;
	static function run(r:Runnable):Void;
	function describe():String;
}

class Task implements Runnable {
	public var n = 0;

	public function new() {}

	public function run()
		n++;
}

class JniElsewhere {
	static function attempt(what:String, f:() -> Void)
		try {
			f();
			trace(what + ": no exception");
		} catch (e:JavaException) {
			trace(what + ": a JavaException", e.throwable == null);
		}

	static function main() {
		trace(Jvm.exists);
		attempt("a static call", () -> Nowhere.add(1, 2));
		attempt("a static field", () -> trace(Nowhere.count));
		attempt("a static field set", () -> Nowhere.count = 3);
		attempt("a constructor", () -> new Nowhere("x"));
		var none:Nowhere = null;
		attempt("an instance call", () -> none.describe());
		attempt("an instance field", () -> none.name = "y");
		var t = new Task();
		t.run();
		attempt("a Haxe object to Java", () -> Nowhere.run(t));
		attempt("Java.same", () -> Java.same(t, t));
		attempt("a JavaArray", () -> JavaArray.ofInts(3));
		trace(t.n, Java.proxies(t));
	}
}
