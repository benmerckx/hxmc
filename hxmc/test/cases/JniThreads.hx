import hxmc.NativeGc;
import hxmc.java.*;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

// JNI and threads (docs/interop.md, "Java (JNI)"): a Haxe thread is attached
// to the JVM at its first call (a daemon thread, its own JNIEnv) and
// detached as it ends; Java threads calling a Haxe object at once are
// attached to the runtime, while Haxe threads allocate and collect.
@:hxmc.java("jnitest.JniThreads") extern class Work {
	final text:String;
	static function work(id:Int, s:String):Work;
	static function calls():Int;
	static function threads():Int;
	static function self():String;
	static function hammer(r:Runnable, threads:Int, times:Int):Int;
}

@:hxmc.java("java.lang.Runnable") extern interface Runnable {
	function run():Void;
}

class Tally implements Runnable {
	public var n = 0;

	var m = new Mutex();

	public function new() {}

	public function run() {
		var s = [for (i in 0...20) i].join(",");
		m.acquire();
		n += s.length > 0 ? 1 : 0;
		m.release();
	}
}

class JniThreads {
	static function main() {
		Jvm.create(["-Djava.class.path=classes", "-Xcheck:jni"]);
		trace(Work.self());
		var base = Work.threads();
		// Haxe threads calling Java at once
		var n = 8, per = 300;
		var done = new Lock();
		var ok = new sys.thread.Deque<Int>();
		var names = [];
		var m = new Mutex();
		for (t in 0...n)
			Thread.create(() -> {
				var good = 0;
				for (i in 0...per) {
					var w = Work.work(i, "t" + t);
					if (w.text == "t" + t + "#" + i) good++;
					if (i % 100 == 0) NativeGc.collect(false);
				}
				m.acquire();
				names.push(Work.self());
				m.release();
				ok.add(good);
				done.release();
			});
		var good = 0;
		for (t in 0...n) {
			done.wait();
			good += ok.pop(true);
		}
		trace(good, Work.calls(), names[0], names.length);
		// (their threads ended: detached; the JVM's count back where it was)
		var tries = 0;
		while (Work.threads() > base && tries++ < 200)
			Sys.sleep(0.01);
		trace("threads back", Work.threads() == base);
		// Java threads calling Haxe at once, while this thread collects
		var tally = new Tally();
		var stop = false;
		Thread.create(() -> {
			while (!stop) {
				var junk = [for (i in 0...500) "j" + i];
				NativeGc.collect(false);
			}
			done.release();
		});
		trace(Work.hammer(tally, 6, 400), tally.n);
		stop = true;
		done.wait();
	}
}
