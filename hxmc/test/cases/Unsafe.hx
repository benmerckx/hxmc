// The low-level intrinsics the runtime's Haxe code is written with
// (hxmc.unsafe: Mem, Atomic, Ptr, LibC; @:hxmc.noGc), exercised directly.
import hxmc.I64;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class Unsafe {
	static inline var T_STRING = hxmc.rt.Types.T_STRING;
	static inline var K_RAW = 2;

	// a string of n units, every one c, built by hand (hxmc.rt.Types: the
	// header's words and hash 0; the length at offset 0, the UTF-16 units
	// from offset 4; none: the static empty string, every heap object having
	// a slot)
	static function makeString(n:Int, c:Int):String {
		if (n == 0) return "";
		var s:String = Mem.allocArrayRaw(T_STRING, 0, (n + 5) >> 2);
		var p = Mem.addr(s);
		Mem.setI32(p, 0, n);
		for (i in 0...n)
			Mem.setU16At(p, 4, i, c);
		return s;
	}

	// raw addresses across C calls: no GC point between taking and using them
	@:hxmc.noGc static function sumUnits(s:String):Int {
		var p = Mem.addr(s);
		var n = Mem.getI32(p, 0), t = 0;
		for (i in 0...n)
			t += Mem.getU16At(p, 4, i);
		return t;
	}

	@:hxmc.noGc static function copyUnits(dst:String, src:String, n:Int):Void {
		LibC.memcpy(Mem.addr(dst).add(4), Mem.addr(src).add(4), (2 * n : I64));
	}

	static function main() {
		// loads and stores of every width on a malloc'ed block
		var b = LibC.malloc(64);
		LibC.memset(b, 0, 64);
		Mem.setI8(b, 0, -2);
		Mem.setI16(b, 2, -3);
		Mem.setI32(b, 4, 0x7fffffff);
		Mem.setI64(b, 8, (0x12345678 : I64) * (0x1000 : I64));
		Mem.setF64(b, 16, 1.5);
		Mem.setF32(b, 24, 0.25);
		Mem.setPtr(b, 32, b);
		Sys.println([Mem.getI8(b, 0), Mem.getU8(b, 0), Mem.getI16(b, 2), Mem.getU16(b, 2), Mem.getI32(b, 4)].join(" "));
		Sys.println(Std.string(Mem.getI64(b, 8) == (0x12345678 : I64) * (0x1000 : I64)) + " " + Mem.getF64(b, 16) + " " + Mem.getF32(b, 24));
		Sys.println(Mem.getPtr(b, 32) == b ? "ptr ok" : "ptr bad");
		var off = 4;
		Sys.println(Mem.getI32(b, off) + Mem.getI32(b.add(4), 0) == -2 ? "offsets ok" : "offsets bad");
		Mem.setI32At(b, 40, 1, 77);
		Sys.println(Mem.getI32At(b, 40, 1) == 77 && Mem.getI32(b, 44) == 77 ? "indexed ok" : "indexed bad");
		Sys.println(b.add(8).diff(b) == (8 : I64) && b.ult(b.add(1)) && !b.add(1).ult(b) ? "ptr arith ok" : "ptr arith bad");
		// atomics
		var a = b.add(48);
		Atomic.store32(a, 5);
		Sys.println([Atomic.add32(a, 3), Atomic.load32(a), Atomic.exchange32(a, 10), Atomic.cas32(a, 9, 1), Atomic.cas32(a, 10, 2), Atomic.load32(a)].join(" "));
		var l = b.add(56);
		Atomic.store64(l, (1 : I64) << 40);
		var old = Atomic.add64(l, 1);
		Sys.println(old == (1 : I64) << 40 && Atomic.load64(l) == ((1 : I64) << 40) + (1 : I64) ? "atomic64 ok" : "atomic64 bad");
		Sys.println(Atomic.cas64(l, 0, 5) == ((1 : I64) << 40) + (1 : I64) && Atomic.exchange64(l, 7) == ((1 : I64) << 40) + (1 : I64) && Atomic.load64(l) == (7 : I64) ? "cas64 ok" : "cas64 bad");
		Atomic.fence();
		LibC.free(b);
		// heap objects made and read by hand, across collections
		var keep = [];
		for (k in 0...2000) {
			var s = makeString(k % 50, 65 + k % 26);
			if (k % 97 == 0) keep.push(s);
		}
		var total = 0;
		for (s in keep)
			total += sumUnits(s) + s.length;
		Sys.println("strings " + keep.length + " " + total + " " + keep[3]);
		var dst = makeString(5, 46);
		copyUnits(dst, "hello", 5);
		Sys.println(dst + " " + (dst == "hello"));
		// zeroed objects: an Int array's raw data block is all zero
		var z = Mem.alloc(3, hxmc.rt.Types.T_ADATA_RAW, K_RAW);
		Sys.println(Mem.getI64(Mem.addr(z), 0) == 0 && Mem.getI64(Mem.addr(z), 16) == 0 ? "zeroed" : "not zeroed");
		// the target, as the code generator knows it
		Sys.println(Mem.os() >= 0 && Mem.os() <= 3 ? "os ok" : "os bad");
		// a frame area
		var st = Mem.stack(16);
		Mem.setI64(st, 8, 99);
		Sys.println(Mem.getI64(st, 8) == 99 ? "stack ok" : "stack bad");
		Sys.println(Mem.abi("TYPE_SIZE"));
	}
}
