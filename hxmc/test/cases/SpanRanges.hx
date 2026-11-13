import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// Range checks a test before them proves (Opt.fits: FnLower's ult(n, p +
// q) of a sub, fill or blit): p < 0 and p > n - k tested for a constant k,
// p, q < 0 and p > n - q for any q. A reinterpreted sub's one element: its
// length folded (4 / 4), its check gone. A kernel's span code is judged on
// its Mir to be inlined (Inline.candidate): `at`, called at three places,
// is inlined at each, and keeps its check where nothing proves it (p only
// below n: its 4 bytes may pass the end).
// range-checks: R.word=0 R.fill=0 R.unproved=1 R.near=1
// span-checks: R.word=0
@:hxmc.kernel class R {
	public static function word(s:ReadOnlySpan<UInt8>, p:Int):Int {
		if (p < 0 || p > s.length - 4) return -1;
		return at(s, p);
	}

	public static function fill(s:Span<UInt8>, p:Int, q:Int):Int {
		if (p < 0 || q < 0 || p > s.length - q) return -1;
		s.fill(p, q, 7);
		return q;
	}

	public static function unproved(s:ReadOnlySpan<UInt8>, p:Int):Int
		return at(s, p);

	public static function near(s:ReadOnlySpan<UInt8>, p:Int):Int {
		if (p < 0 || p >= s.length) return -1;
		return at(s, p);
	}

	static function at(s:ReadOnlySpan<UInt8>, p:Int):Int {
		var w:ReadOnlySpan<Int> = s.sub(p, 4).reinterpret();
		return w[0];
	}
}

class SpanRanges {
	static function main() {
		var b = Bytes.alloc(10);
		for (i in 0...10)
			b.set(i, i + 1);
		trace(R.word(ReadOnlySpan.ofBytes(b), 0), R.word(ReadOnlySpan.ofBytes(b), 6), R.word(ReadOnlySpan.ofBytes(b), 7), R.word(ReadOnlySpan.ofBytes(b), -1));
		trace(R.unproved(ReadOnlySpan.ofBytes(b), 2), R.near(ReadOnlySpan.ofBytes(b), 6), R.near(ReadOnlySpan.ofBytes(b), 10));
		trace(R.fill(Span.ofBytes(b), 2, 3), R.fill(Span.ofBytes(b), 8, 2), R.fill(Span.ofBytes(b), 9, 2), R.fill(Span.ofBytes(b), 0, -1), b.toHex());
		trace(R.fill(Span.ofBytes(b), 0, 10), R.fill(Span.ofBytes(b), 10, 0), b.toHex());
	}
}
