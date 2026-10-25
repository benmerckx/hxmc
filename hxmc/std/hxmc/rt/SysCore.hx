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
	// s as a C string, UTF-8 ("null" for null), on the data stack
	// (hxmc.scoped.Str.utf8Of): valid until the function, or the loop
	// iteration, that made it ends (typed under -D hxmc.wasm-gc, never run:
	// hxmc.rt.gc.GcSys)
	public static inline function cstr(s:String):Ptr
		return #if hxmc.wasm_gc Str.toUtf8(s) #else hxmc.scoped.Str.utf8Of(s).ptr() #end;

	// s as a C string (cstr) for a call taking views (hxmc.unsafe.Posix)
	public static inline function cref(s:String):hxmc.scoped.Ref<hxmc.unsafe.UInt8>
		return #if hxmc.wasm_gc hxmc.scoped.Ref.nil() #else hxmc.scoped.Ref.raw(cstr(s)) #end;

	// the C string at r + off, memory of C's (UTF-8), as a String (null for none)
	public static inline function ofC(r:hxmc.scoped.Ref<hxmc.unsafe.UInt8>, off = 0):String {
		#if hxmc.wasm_gc
		return null;
		#else
		if (r.isNull()) return null;
		var p = r.ptr().add(off);
		return Str.ofUtf8(p, LibC.strlen(p).toInt());
		#end
	}

	// s as a wide C string, UTF-16, on the data stack (hxmc.scoped.Str.copyOf),
	// for a call taking views (hxmc.unsafe.Win32)
	public static inline function wref(s:String):hxmc.scoped.Ref<hxmc.unsafe.UInt16>
		return #if hxmc.wasm_gc hxmc.scoped.Ref.nil() #else hxmc.scoped.Ref.raw(hxmc.scoped.Str.copyOf(s).ptr()) #end;

	// s to a descriptor, as UTF-8
	public static inline function printTo(fd:Int, s:String) {
		#if !hxmc.wasm_gc // (typed under WasmGC, never run: hxmc.rt.gc.GcSys)
		var u = hxmc.scoped.Str.utf8Of(s);
		if (Mem.os() == 2) WinSys.writeAll(fd, u) else PosixSys.writeAll(fd, u);
		#end
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
		return #if (hxmc.target == "wasm32-wasi") WasiSys.rw(true, fd, p, n) #else Mem.os() == 2 ? Win32._write(fd, hxmc.scoped.Slice.raw(p, n)) : Posix.write(fd, hxmc.scoped.Slice.raw(p, n)).toInt() #end;

	// (POSIX: a negative count; Windows and WASI: none written either)
	static inline function writeFailed(w:Int):Bool
		return #if (hxmc.target == "wasm32-wasi") w <= 0 #else Mem.os() == 2 ? w <= 0 : w < 0 #end;

	static inline function close(fd:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiApi.fd_close(fd) #else Mem.os() == 2 ? Win32._close(fd) : Posix.close(fd) #end;
}
