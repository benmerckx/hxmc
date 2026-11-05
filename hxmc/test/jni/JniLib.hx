import hxmc.NativeGc;
import hxmc.java.*;
import hxmc.unsafe.*;

// hxmc's code loaded into a JVM (docs/interop.md, "Java (JNI)"): a shared
// library (-D hxmc.shared in the glibc mode; Android's lib<name>.so is one)
// exporting JNI_OnLoad (-D hxmc.exports=JNI_OnLoad), which Java's
// System.loadLibrary calls: Jvm.onLoad keeps the JVM and the loader of the
// classes, runs main on a thread of its own and waits for it. main gives
// Java a Haxe object implementing its interface; Java calls it afterwards,
// on its own threads (JniHost.java, run by JniCheck).
@:hxmc.java("jnihost.JniHost$Handler") extern interface Handler {
	function handle(s:String, n:Int):String;
}

@:hxmc.java("jnihost.JniHost") extern class Host {
	static function register(h:Handler):Void;
	static function log(s:String):Void;
	static function thread():String;
}

class Echo implements Handler {
	var calls = 0;
	var m = new sys.thread.Mutex();

	public function new() {}

	public function handle(s:String, n:Int):String {
		if (s == null) throw "no string";
		m.acquire();
		var k = ++calls;
		m.release();
		var parts = [for (i in 0...n) s];
		if (k % 50 == 0) NativeGc.collect(false);
		return parts.join("-") + " #" + k + " on " + Host.thread();
	}
}

class JniLib {
	@:hxmc.export("JNI_OnLoad") @:hxmc.unsafe static function onLoad(vm:Ptr, reserved:Ptr):Int
		return Jvm.onLoad(vm);

	static function main() {
		Host.log("main runs at load, " + Host.thread() + ", Jvm.exists " + Jvm.exists);
		Host.register(new Echo());
	}
}
