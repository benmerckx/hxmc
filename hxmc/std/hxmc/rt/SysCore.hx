package hxmc.rt;

import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.Win32;
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.wasm.WasiApi;
#end

// What the system layers (PosixSys, WinSys, WasiSys) do the same way,
// written once over the calls that differ: inline, with the system chosen
// by Mem.os (which folds while lowering) and WASI by the target (its layer
// is typed only for it), so each layer keeps only its own calls and
// compiles to what its own copy did. POSIX retries a call EINTR
// interrupted; Windows and WASI have no signals to interrupt one.
@:access(hxmc.rt.PosixSys) @:access(hxmc.rt.WinSys) #if (hxmc.target == "wasm32-wasi") @:access(hxmc.rt.WasiSys) #end
extern class SysCore {
	// s to a descriptor, as UTF-8
	public static inline function printTo(fd:Int, s:String) {
		var u = Str.toUtf8(Str.orNull(s));
		if (Mem.os() == 2) WinSys.writeAll(fd, u, LibC.strlen(u).toInt()) else PosixSys.writeAll(fd, u, LibC.strlen(u).toInt());
		LibC.free(u);
	}

	// n bytes at d written to fd, which is then closed: false when either failed
	public static inline function saveAll(fd:Int, d:Ptr, n:Int):Bool {
		// (Windows: the pages faulted in first, WinSys.touch)
		if (Mem.os() == 2) WinSys.touch(d, n);
		var ok = true;
		while (n > 0) {
			var w = write(fd, d, n);
			if (writeFailed(w)) {
				#if (hxmc.target != "wasm32-wasi")
				if (Mem.os() != 2) if (PosixSys.errno() == PosixSys.EINTR) continue;
				#end
				ok = false;
				break;
			}
			d = d.add(w);
			n -= w;
		}
		return close(fd) == 0 && ok;
	}

	// ---- the calls

	static inline function write(fd:Int, p:Ptr, n:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.rw(true, fd, p, n) #else Mem.os() == 2 ? Win32._write(fd, p, n) : Posix.write(fd, p, n).toInt() #end;

	// (POSIX: a negative count; Windows and WASI: none written either)
	static inline function writeFailed(w:Int):Bool
		return #if (hxmc.target == "wasm32-wasi") w <= 0 #else Mem.os() == 2 ? w <= 0 : w < 0 #end;

	static inline function close(fd:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiApi.fd_close(fd) #else Mem.os() == 2 ? Win32._close(fd) : Posix.close(fd) #end;
}
