import hxmc.unsafe.*;

// The smallest Android app (make android-check, android-device-check): a
// NativeActivity's library, its entry ANativeActivity_onCreate in no-GC
// Haxe (Android calls it on the activity's UI thread, which the runtime does
// not know). It starts a thread for the program: hxmc's generated main (the
// runtime, then main below), whose lines go to logcat under the tag "hxmc";
// then the activity finishes and the process ends.
@:keep
class AndroidHello {
	static var activity:Ptr;

	@:hxmc.export("ANativeActivity_onCreate") @:hxmc.noGc static function onCreate(a:Ptr, saved:Ptr, savedSize:Int64):Void {
		activity = a;
		var t = Mem.stack(8);
		Threads.pthread_create(t, Ptr.nil(), Callback.addr(programThread), Ptr.nil());
	}

	@:hxmc.callback @:hxmc.noGc static function programThread(arg:Ptr):Ptr {
		var argv = Mem.stack(16);
		Mem.setPtr(argv, 0, Mem.cstr("app"));
		Mem.setPtr(argv, 8, Ptr.nil());
		Threads.main(1, argv);
		Android.ANativeActivity_finish(activity);
		return Ptr.nil();
	}

	static function log(s:String) {
		var p = LibC.malloc((s.length + 1 : Int64));
		for (i in 0...s.length) Mem.setI8(p, i, s.charCodeAt(i));
		Mem.setI8(p, s.length, 0);
		Log.__android_log_write(4, Mem.cstr("hxmc"), p);
		LibC.free(p);
	}

	static function main() {
		// (the collector, a map, an exception: the runtime at work)
		var squares = [for (i in 0...1000) Std.string(i * i)];
		var m = new Map<String, Int>();
		for (s in squares) m[s] = s.length;
		var caught = try {
			throw "boom";
		} catch (e:String) e;
		log('hello from hxmc on ' + Sys.systemName() + ': ' + squares[999] + ' ' + m["998001"] + ' ' + caught);
	}
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("libandroid.so") extern class Android {
	static function ANativeActivity_finish(activity:Ptr):Void;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("liblog.so") extern class Log {
	static function __android_log_write(prio:Int, tag:Ptr, text:Ptr):Int;
}

@:hxmc.c @:hxmc.fast extern class Threads {
	static function pthread_create(t:Ptr, attr:Ptr, entry:Ptr, arg:Ptr):Int;
	// the program's main (hxmc's generated one, C's convention)
	static function main(argc:Int, argv:Ptr):Int;
}
