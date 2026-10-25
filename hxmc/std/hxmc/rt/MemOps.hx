package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Byte comparisons of the runtime (strings, Bytes.compare): 8 bytes at a
// time while equal, then byte by byte. musl's memcmp compares one byte at a
// time (hxmc/c/rtlibc.c once replaced it on Linux); the C library's own
// stays for C code. WebAssembly's memcmp (wasm/Heap.hx) is this.
class MemOps {
	@:hxmc.noGc #if !hxmc.wasm_gc @:hxmc.scoped #end public static function compare(a:Ptr, b:Ptr, n:I64):Int {
		var k = n.toInt();
		var i = 0;
		while (i + 8 <= k && Mem.getI64(a, i) == Mem.getI64(b, i))
			i += 8;
		while (i < k) {
			var x = Mem.getU8(a, i), y = Mem.getU8(b, i);
			if (x != y) return x - y;
			i++;
		}
		return 0;
	}
}
