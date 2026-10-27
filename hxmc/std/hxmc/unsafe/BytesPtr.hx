package hxmc.unsafe;

import haxe.io.Bytes;

// A haxe.io.Bytes where C (a C function, an import of the host) reads or
// writes it: its BytesData's bytes, by address (no copy; valid until the
// next GC point, as Mem.addr).
class BytesPtr {
	// the address of b's bytes [pos, pos + n), for C to read
	public static inline function of(b:Bytes, pos:Int, n:Int):Ptr {
		return Mem.addr(b.getData()).add(pos);
	}

	// after C wrote at p = of(b, pos, n): b's bytes as C left them (nothing to
	// do: C wrote into them)
	public static inline function written(b:Bytes, pos:Int, p:Ptr, n:Int) {
	}

	// the n bytes at p (C's) into b at pos
	public static inline function copyIn(b:Bytes, pos:Int, p:Ptr, n:Int) {
		LibC.memcpy(Mem.addr(b.getData()).add(pos), p, (n : hxmc.I64));
	}
}
