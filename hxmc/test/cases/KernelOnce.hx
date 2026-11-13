import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

// A kernel called at one place of its module is inlined there whatever its
// loops (Inline.once: Str's search, a kernel per pair of widths), and so is
// one that one calls once: their checks the loops cannot prove are the
// caller's. One called at two places stays a call.
// span-checks: O.once=1 O.chain=1 O.twice=0 O.rotated=1 O.rotatedTwice=1
@:hxmc.kernel class O {
	public static function once(s:ReadOnlySpan<UInt8>):Int
		return rotated(s, 3);

	public static function chain(s:ReadOnlySpan<UInt8>):Int
		return middle(s) + 1;

	static function middle(s:ReadOnlySpan<UInt8>):Int
		return rotatedTwice(s, 5);

	public static function twice(s:ReadOnlySpan<UInt8>):Int
		return shared(s, 1) * 31 + shared(s, 2);

	// (the index wraps by a modulo: its check stays)
	static function rotated(s:ReadOnlySpan<UInt8>, k:Int):Int {
		var t = 0;
		for (i in 0...s.length)
			t = t * 7 + s[(i + k) % s.length];
		return t;
	}

	static function rotatedTwice(s:ReadOnlySpan<UInt8>, k:Int):Int {
		var t = 0;
		for (i in 0...s.length)
			t = t * 5 + s[(i + k) % s.length];
		return t;
	}

	static function shared(s:ReadOnlySpan<UInt8>, k:Int):Int {
		var t = 0;
		for (i in 0...s.length)
			t = t * 3 + s[(i + k) % s.length];
		return t;
	}
}

class KernelOnce {
	static function main() {
		var b = Bytes.ofString("kernels");
		Sys.println([O.once(ReadOnlySpan.ofBytes(b)), O.chain(ReadOnlySpan.ofBytes(b)), O.twice(ReadOnlySpan.ofBytes(b))]);
	}
}
