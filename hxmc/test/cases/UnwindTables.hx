// The unwind tables of the generated code (hxmc/src/hxmc/Unwind.hx), read by
// the system's own unwinders, which use no frame pointers: glibc's
// backtrace() (the dynamic glibc mode: libgcc's DWARF unwinder through
// .eh_frame_hdr and .eh_frame), Windows' RtlCaptureStackBackTrace
// (RtlLookupFunctionEntry and RtlVirtualUnwind through .pdata and .xdata)
// and macOS's _Unwind_Backtrace (libunwind through __eh_frame). From the
// bottom of a recursion, of a closure the runtime's sort calls back, and
// after an exception was caught, each must pass the return addresses the
// frame-pointer chain gives (FrameChain), in order, up to main's frame.
// Where there is no such unwinder (static musl, WebAssembly) the checks
// are skipped (the output is the same).
import hxmc.unsafe.Callback;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;

// (each used only on its system: the other targets fold its calls away, Mem.target)
@:hxmc.c extern class Ind {
	@:hxmc.indirect static function backtrace(f:Ptr, buf:Ptr, size:Int):Int;
}

@:hxmc.c @:hxmc.lib("kernel32") extern class Kernel32 {
	static function RtlCaptureStackBackTrace(skip:Int, n:Int, buf:Ptr, hash:Ptr):Int;
}

@:hxmc.c extern class LibUnwind {
	static function _Unwind_Backtrace(fn:Ptr, arg:Ptr):Int;
	@:hxmc.fast static function _Unwind_GetIP(ctx:Ptr):Ptr;
}

class UnwindTables {
	static inline var MAX = 512;

	static var top:Ptr;
	static var buf:Ptr;
	static var count = 0;
	static var sink:Array<Array<Int>> = [];

	// (_Unwind_Backtrace's callback: each frame's address)
	@:hxmc.callback @:hxmc.unsafe static function step(ctx:Ptr, arg:Ptr):Int {
		if (count >= MAX) return 5; // _URC_END_OF_STACK
		Mem.setPtr(buf, 8 * count, LibUnwind._Unwind_GetIP(ctx));
		count++;
		return 0;
	}

	// the system unwinder's return addresses from here (count of them in
	// buf), or -1 where there is none
	static function unwind():Int {
		if (Mem.target() >= 7) {
			// (glibc's backtrace, looked up: the static musl mode has none; no
			// frame at all when libgcc_s, its unwinder, is missing: a cross C
			// library under qemu)
			var f = Posix.dlsym(Ptr.nil(), Mem.cstr("backtrace"));
			var n = Ind.backtrace(f, buf, MAX);
			return n == 0 ? -1 : n;
		}
		if (Mem.os() == 2) return Kernel32.RtlCaptureStackBackTrace(0, MAX - 1, buf, Ptr.nil()) & 0xffff; // (a USHORT)
		if (Mem.os() == 1) {
			count = 0;
			LibUnwind._Unwind_Backtrace(Callback.addr(step), Ptr.nil());
			return count;
		}
		return -1;
	}

	// the frame-pointer chain's return addresses from the caller's frame up to
	// main's, against the unwinder's: they must follow each other in its list
	static function walk():String {
		var n = unwind();
		var f = Mem.frame();
		if (n < 0 || top.isNull()) return "ok";
		var rets:Array<Ptr> = [];
		while (f != top) {
			var up = Mem.getPtr(f, 0);
			if (up.isNull() || !f.ult(up) || rets.length > 100000) return "broken frame chain";
			rets.push(Mem.getPtr(f, 8));
			f = up;
		}
		if (rets.length == 0) return "no frames";
		var at = -1;
		for (k in 0...n)
			if (Mem.getPtr(buf, 8 * k) == rets[0]) {
				at = k;
				break;
			}
		if (at < 0) return 'the unwinder missed the caller (${n} frames)';
		for (k in 0...rets.length)
			if (at + k >= n || Mem.getPtr(buf, 8 * (at + k)) != rets[k]) return 'the unwinder stopped or strayed at frame ${k} of ${rets.length} (${n} frames)';
		return "ok";
	}

	// (allocates on the way down: collections happen during the recursion)
	static function rec(n:Int):String {
		sink.push([for (i in 0...64) i * n]);
		if (sink.length > 32) sink.shift();
		if (n == 0) return walk();
		var r = rec(n - 1);
		return r;
	}

	static function throwAt(n:Int):Int {
		if (n == 0) throw "deep";
		return throwAt(n - 1) + 1;
	}

	static function main() {
		top = Mem.frame();
		buf = LibC.malloc(8 * MAX);
		Sys.println("recursion: " + rec(40));
		var inSort:Null<String> = null;
		var a = [3, 1, 2];
		a.sort((x, y) -> {
			if (inSort == null) inSort = walk();
			return x - y;
		});
		Sys.println("runtime callback: " + inSort);
		var afterCatch = "";
		try {
			throwAt(10);
		} catch (e:String) {
			afterCatch = walk();
		}
		Sys.println("after catch: " + afterCatch);
		Sys.println("after throw: " + rec(5));
		LibC.free(buf);
	}
}
