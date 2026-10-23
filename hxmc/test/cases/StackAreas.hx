// build-seconds: 10
// Frame areas (Mem.stack) whose sizes are not multiples of 8, kept in memory
// by a C call that takes their addresses, then read back: x86-64's frame
// layout rounded the frame up to 16 bytes in steps of 8 from where the slots
// end, which from an end that is not a multiple of 8 it never reached (the
// build hung). The areas are 16-byte aligned, whatever their sizes.
import hxmc.I64;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class StackAreas {
	static function aligned(p:Ptr):String
		return (p.toI64() & (15 : I64)) == (0 : I64) ? "aligned" : "misaligned";

	// one area of 28 bytes, the last slot of the frame
	static function one(c:Int):String {
		var a = Mem.stack(28);
		LibC.memset(a, c, 28);
		return ((Mem.getU8(a, 2) << 8) | Mem.getU8(a, 27)) + " " + aligned(a);
	}

	// two areas, the frame's slots ending at 36 bytes
	static function two(c:Int):String {
		var a = Mem.stack(28);
		var b = Mem.stack(4);
		LibC.memset(a, c, 28);
		LibC.memset(b, c + 1, 4);
		return (Mem.getU8(a, 0) + Mem.getU8(a, 27) + Mem.getU8(b, 3)) + " " + aligned(a) + " " + aligned(b);
	}

	// an area of 1 byte, the result of the call read too
	static function byte(c:Int):String {
		var a = Mem.stack(1);
		if (LibC.memset(a, c, 1) != a) return "memset's result";
		return Mem.getU8(a, 0) + " " + aligned(a);
	}

	// areas of 13 and 3 bytes, one copied into the other
	static function copy(c:Int):String {
		var a = Mem.stack(13);
		var b = Mem.stack(3);
		LibC.memset(a, c, 13);
		LibC.memcpy(b, a.add(10), 3);
		return (Mem.getU8(b, 0) + Mem.getU8(b, 2)) + " " + aligned(a) + " " + aligned(b);
	}

	static function main() {
		Sys.println(one(7));
		Sys.println(two(7));
		Sys.println(byte(9));
		Sys.println(copy(5));
	}
}
