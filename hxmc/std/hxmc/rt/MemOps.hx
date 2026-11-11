package hxmc.rt;

import hxmc.ReadOnlySpan;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// Byte comparisons of the runtime (strings, Bytes.compare): 8 bytes at a
// time while equal, then byte by byte. musl's memcmp compares one byte at a
// time (hxmc/c/rtlibc.c once replaced it on Linux); the C library's own
// stays for C code. WebAssembly's memcmp (wasm/Heap.hx) is this.
class MemOps {
	// the difference of the first differing bytes of a and b[0, a.length), else 0
	@:hxmc.kernel public static function compare(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>):Int
		return bytes(a, b);

	// compare of the n bytes at a and b (raw memory: its caller vouches for it)
	@:hxmc.kernel @:hxmc.unsafe public static function compareAt(a:Ptr, b:Ptr, n:hxmc.I64):Int {
		var k = n.toInt();
		return bytes(ReadOnlySpan.unsafeOf((cast a : Ptr<UInt8>), k), ReadOnlySpan.unsafeOf((cast b : Ptr<UInt8>), k));
	}

	// (b as long as a: one length, its words' and bytes' checks proved,
	// Opt.fits; i + 8 <= n: i < n - 7)
	static inline function bytes(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>):Int {
		var n = a.length, c = b.sub(0, n), i = 0;
		while (i < n - 7 && a.getI64(i) == c.getI64(i))
			i += 8;
		var r = 0;
		while (i < n) {
			var x:Int = a[i], y:Int = c[i];
			if (x != y) {
				r = x - y;
				break;
			}
			i++;
		}
		return r;
	}
}
