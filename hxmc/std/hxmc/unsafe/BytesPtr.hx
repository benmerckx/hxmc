package hxmc.unsafe;

import haxe.io.Bytes;

// A haxe.io.Bytes where C (a C function, an import of the host) reads or
// writes it. In linear memory: its BytesData's bytes, by address (no copy;
// valid until the next GC point, as Mem.addr). Under -D hxmc.wasm-gc a
// BytesData is an array of the engine's collector, which C cannot see: its bytes
// are copied through the module's linear memory (hxmc.rt.gc.GcRepr.lend: a
// buffer kept for this, valid until the next `of`).
class BytesPtr {
	// the address of b's bytes [pos, pos + n), for C to read
	public static inline function of(b:Bytes, pos:Int, n:Int):Ptr {
		#if (hxmc.wasm_gc)
		return hxmc.rt.gc.GcRepr.lend(b.getData(), pos, n);
		#else
		return Mem.addr(b.getData()).add(pos);
		#end
	}

	// after C wrote at p = of(b, pos, n): b's bytes as C left them
	public static inline function written(b:Bytes, pos:Int, p:Ptr, n:Int) {
		#if (hxmc.wasm_gc)
		copyIn(b, pos, p, n);
		#end
	}

	// the n bytes at p (C's) into b at pos
	public static inline function copyIn(b:Bytes, pos:Int, p:Ptr, n:Int) {
		#if (hxmc.wasm_gc)
		hxmc.rt.gc.W.memToBytes(b.getData(), pos, p, n);
		#else
		LibC.memcpy(Mem.addr(b.getData()).add(pos), p, (n : hxmc.I64));
		#end
	}
}
