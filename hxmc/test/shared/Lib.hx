import hxmc.unsafe.*;

// A shared library written by hxmc (-D hxmc.shared, in the dynamic glibc
// mode; Android's lib<name>.so is one too), loaded by Host with dlopen: its
// export lib_run starts the runtime on a thread of its own (the program's
// main, as an Android app's ANativeActivity_onCreate does) and returns what
// main left in an exported static. Position-independent code (RELATIVE
// relocations of the type tables, closures and strings), thread-locals
// through TLSDESC (the collector's), imports through GOT slots, threads,
// exceptions.
@:hxmc.c @:hxmc.fast extern class P {
	static function pthread_create(t:Ptr, attr:Ptr, fn:Ptr, arg:Ptr):Int;
	static function pthread_join(t:Int64, ret:Ptr):Int;
	// the program's main (DataGen), C's convention
	static function main(argc:Int, argv:Ptr):Int;
}

class Lib {
	@:hxmc.export("lib_result") static var result:Int = 0;

	// the library's entry: the runtime runs main on a thread it starts
	@:hxmc.export("lib_run") @:hxmc.unsafe static function run(arg:Int):Int {
		var t = Mem.stack(16);
		if (P.pthread_create(t, Ptr.nil(), Callback.addr(thread), Ptr.ofI64(arg)) != 0) return -1;
		P.pthread_join(Mem.getI64(t, 0), Ptr.nil());
		return result;
	}

	@:hxmc.callback @:hxmc.unsafe static function thread(arg:Ptr):Ptr {
		P.main(0, Ptr.nil());
		return Ptr.nil();
	}

	static function main() {
		var parts = [for (i in 0...5) "p" + i];
		var m = new Map<String, Int>();
		for (p in parts)
			m.set(p, p.length * 3);
		var sum = 0;
		for (k => v in m)
			sum += v;
		var caught = try {
			throw "boom";
			"";
		} catch (e:String) e;
		var env = Sys.getEnv("HXMC_SHARED_CHECK") != null;
		var lock = new sys.thread.Lock();
		var fromThread = 0;
		sys.thread.Thread.create(() -> {
			var a = [for (i in 0...1000) Std.string(i)];
			fromThread = a.join(",").length;
			lock.release();
		});
		lock.wait();
		Sys.println('lib: ${parts.join(",")} $sum $caught env=$env thread=$fromThread');
		result = sum + (env ? 1000 : 0) + fromThread;
	}
}
