import hxmc.I64;
import hxmc.Platform;
import hxmc.unsafe.*;

// What a major collection frees goes back to the system: 40 MB of small
// objects promoted, dropped and collected, the process's memory as the system
// counts it falls by most of it (Apple's phys_footprint, what iOS ends an app
// for; Linux's resident set). macOS used to keep it: madvise's MADV_DONTNEED
// there leaves the pages dirty and counted (Os.decommit). Windows' decommit
// and WebAssembly's memory (never given back) are not measured.
@:hxmc.c extern class Usage {
	static function getpid():Int;
	static function proc_pid_rusage(pid:Int, flavor:Int, buffer:Ptr):Int;
}

class GcRelease {
	static var hold:Array<Array<Float>>;

	static function main() {
		fill();
		hxmc.NativeGc.collect(true);
		hxmc.NativeGc.collect(true);
		var before = used();
		hold = null;
		hxmc.NativeGc.collect(true);
		hxmc.NativeGc.collect(true);
		var after = used();
		var measured = before >= 0 && after >= 0;
		Sys.println("released: " + (!measured || before - after > 24.0 * 1048576));
		if (measured && before - after <= 24.0 * 1048576) Sys.println("held: " + Std.int(before / 1048576) + " MB, then " + Std.int(after / 1048576) + " MB");
	}

	// 40 MB live in 5000 arrays of a thousand floats (8 KB each: small objects)
	static function fill() {
		hold = [];
		for (i in 0...5000) {
			var a = [for (j in 0...1000) j * 1.0];
			hold.push(a);
		}
	}

	// the process's memory as its system counts it, in bytes; -1 not measured
	@:hxmc.unsafe(gc) static function used():Float {
		if (Platform.os() == Platform.MACOS) {
			// (rusage_info_v2: phys_footprint after the uuid and seven counters)
			var buf = IoBuffer.alloc(256);
			var ok = Usage.proc_pid_rusage(Usage.getpid(), 2, buf.ptr) == 0;
			var f:Float = ok ? cast Mem.getI64(buf.ptr, 72) : -1;
			buf.free();
			return f;
		}
		if (Platform.os() == Platform.LINUX) {
			var statm = sys.io.File.getContent("/proc/self/statm").split(" ");
			return Std.parseFloat(statm[1]) * 4096;
		}
		return -1;
	}
}
