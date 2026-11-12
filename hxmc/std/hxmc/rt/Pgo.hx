package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.*;

// Profile-guided optimization on Linux (-D hxmc.llvm-pgo=gen, docs/plans/llvm.md):
// the instrumented program writes its raw profile when it exits, as the
// file part of LLVM's profile runtime does on other systems (that part is C
// built against glibc, whose stdio does not link with musl's). LLVM's own
// writer (lprofWriteData: the header, the records, the counters, the
// bitmaps, the names and the value profiles, in its version's format) runs
// with a writer that writes here; the linker gives it the bounds of the
// sections it walks (__start___llvm_prf_cnts, ...: Link). The counters are
// the program's, every thread's. The file: LLVM_PROFILE_FILE, else
// default.profraw, with %p the process id, %h the host name, %t $TMPDIR and
// %% a %; another pattern (%m, %c, %b) is written as it is.
@:hxmc.native
class Pgo {
	static inline var MAX = 4096;

	@:hxmc.unsafe public static function init():Void
		U.atexit(Callback.addr(write));

	@:hxmc.callback @:hxmc.unsafe static function write():Void {
		var name = Mem.stack(MAX);
		var pat = Posix.getenv(Mem.cstr("LLVM_PROFILE_FILE"));
		if (pat.isNull() || Mem.getU8(pat, 0) == 0) pat = Mem.cstr("default.profraw");
		if (!expand(pat, name)) {
			fail(Mem.cstr("LLVM Profile Error: LLVM_PROFILE_FILE too long\n"));
			return;
		}
		var fd = Posix.open(name, 0x241, 420); // O_WRONLY | O_CREAT | O_TRUNC, 0644
		if (fd < 0) {
			fail(Mem.cstr("LLVM Profile Error: cannot open the profile (LLVM_PROFILE_FILE)\n"));
			return;
		}
		// ProfDataWriter: {Write, WriterCtx}
		var w = Mem.stack(16);
		Mem.setPtr(w, 0, Callback.addr(writeVecs));
		Mem.setPtr(w, 8, Ptr.ofI64(fd));
		var rc = P.lprofWriteData(w, P.lprofGetVPDataReader(), 0);
		if (Posix.close(fd) != 0 || rc != 0) fail(Mem.cstr("LLVM Profile Error: failed to write the profile\n"));
	}

	// the pattern with its % sequences replaced, NUL-terminated (false: too long)
	@:hxmc.unsafe static function expand(pat:Ptr, out:Ptr):Bool {
		var n = 0, i = 0;
		var num = Mem.stack(32);
		inline function put(c:Int):Bool {
			if (n >= MAX - 1) return false;
			Mem.setI8(out, n++, c);
			return true;
		}
		while (true) {
			var c = Mem.getU8(pat, i++);
			if (c == 0) break;
			var s = Ptr.nil();
			if (c == "%".code) {
				var d = Mem.getU8(pat, i);
				if (d == "p".code) {
					// the process id, in decimal
					var v = U.getpid(), k = 31;
					Mem.setI8(num, k, 0);
					do {
						Mem.setI8(num, --k, "0".code + v % 10);
						v = Std.int(v / 10);
					} while (v > 0);
					s = num.add(k);
				} else if (d == "h".code) {
					if (Posix.gethostname(num, 31) != 0) Mem.setI8(num, 0, 0);
					Mem.setI8(num, 31, 0);
					s = num;
				} else if (d == "t".code) {
					s = Posix.getenv(Mem.cstr("TMPDIR"));
					if (s.isNull()) s = Mem.cstr("/tmp");
				} else if (d == "%".code) s = Mem.cstr("%");
				if (!s.isNull()) {
					i++;
					var k = 0;
					while (Mem.getU8(s, k) != 0)
						if (!put(Mem.getU8(s, k++))) return false;
					continue;
				}
			}
			if (!put(c)) return false;
		}
		Mem.setI8(out, n, 0);
		return true;
	}

	// the writer's callback: the vectors {Data, ElmSize, NumElm, UseZeroPadding}
	// written in order (no data: zeros); 0 when all were written
	@:hxmc.callback @:hxmc.unsafe static function writeVecs(w:Ptr, vecs:Ptr, n:Int):Int {
		var fd = Mem.getPtr(w, 8).toI64().toInt();
		var zeros = Mem.stack(256);
		LibC.memset(zeros, 0, 256);
		for (k in 0...n) {
			var v = vecs.add(32 * k);
			var data = Mem.getPtr(v, 0);
			var len:I64 = Mem.getI64(v, 8) * Mem.getI64(v, 16);
			while (len > 0) {
				var chunk:I64 = data.isNull() ? (len > 256 ? 256 : len) : len;
				var r = Posix.write(fd, data.isNull() ? zeros : data, chunk);
				if (r <= 0) return 1;
				if (!data.isNull()) data = data.add(r.toInt());
				len -= r;
			}
		}
		return 0;
	}

	@:hxmc.unsafe static function fail(msg:Ptr):Void
		Posix.write(2, msg, LibC.strlen(msg));

	// A distribution's runtime (Debian's, Ubuntu's) is built with
	// _FORTIFY_SOURCE: its writer prints its warnings with glibc's
	// __fprintf_chk, which musl lacks. They are written unformatted.
	#if (hxmc.llvm_pgo == "gen")
	@:hxmc.export("__fprintf_chk") @:hxmc.unsafe static function fprintfChk(file:Ptr, flag:Int, fmt:Ptr):Int {
		fail(fmt);
		return 0;
	}
	#end
}

// LLVM's profile runtime (compiler-rt's InstrProfilingWriter.c and
// InstrProfilingValue.c, linked from the clang's libclang_rt.profile: Driver)
@:hxmc.c @:hxmc.fast private extern class P {
	static function lprofWriteData(writer:Ptr, vpReader:Ptr, skipNames:Int):Int;
	static function lprofGetVPDataReader():Ptr;
}

@:hxmc.c @:hxmc.fast private extern class U {
	static function atexit(f:Ptr):Int;
	static function getpid():Int;
}
