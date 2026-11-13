import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt16;
import hxmc.unsafe.UInt8;

// Word loads on spans (docs/interop.md, "Spans"): getI64 and getI32, the 8
// or 4 bytes from element i on as one integer, little-endian, any
// alignment, checked as sub(i, 8 / size) is. A loop stepping by the word
// while i < n - 8 (Opt.fits: a counter stepping up by s, below n - c with c
// >= s - 1, is never negative) and a last word at n - 8 after n >= 8 keep
// no check; a word at any i keeps its one (`at`). The bytes after a word
// loop, its counter going on, keep none either (`tail`), nor does all of a
// span (`whole`: s.sub(0, s.length)).
// range-checks: W.sum=0 W.sum2=0 W.last=0 W.at=1 W.tail=0 W.whole=0
// span-checks: W.tail=0
class W {
	@:hxmc.kernel public static function sum(s:ReadOnlySpan<UInt8>):Int {
		var n = s.length, i = 0, x = 0;
		while (i < n - 8) {
			var w = s.getI64(i);
			x = x ^ w.toInt() ^ (w >>> 32).toInt();
			i += 8;
		}
		return x;
	}

	// (4 two-byte units a word)
	@:hxmc.kernel public static function sum2(s:ReadOnlySpan<UInt16>):Int {
		var n = s.length, i = 0, x = 0;
		while (i < n - 4) {
			x = x ^ s.getI32(i) ^ s.getI32(i + 2);
			i += 4;
		}
		return x;
	}

	@:hxmc.kernel public static function units(s:ReadOnlySpan<UInt8>):Int
		return sum2(s.reinterpret());

	@:hxmc.kernel public static function last(s:ReadOnlySpan<UInt8>):Int {
		var n = s.length;
		if (n < 8) return -1;
		return (s.getI64(n - 8) >>> 32).toInt();
	}

	@:hxmc.kernel public static function at(s:ReadOnlySpan<UInt8>, i:Int):Int
		return s.getI32(i);

	@:hxmc.kernel public static function tail(s:ReadOnlySpan<UInt8>):Int {
		var n = s.length, i = 0, x = 0;
		while (i < n - 7) {
			x = x ^ s.getI64(i).toInt();
			i += 8;
		}
		while (i < n) {
			x += s[i];
			i++;
		}
		return x;
	}

	@:hxmc.kernel public static function whole(s:ReadOnlySpan<UInt8>):Int
		return W.tail(s.sub(0, s.length));
}

class SpanWords {
	static function main() {
		var b = Bytes.alloc(21);
		for (i in 0...21)
			b.set(i, i * 7 + 1);
		trace(StringTools.hex(W.sum(ReadOnlySpan.ofBytes(b))), StringTools.hex(W.last(ReadOnlySpan.ofBytes(b))), StringTools.hex(W.at(ReadOnlySpan.ofBytes(b), 3)));
		trace(StringTools.hex(W.units(ReadOnlySpan.ofBytes(b, 1, 20))), W.last(ReadOnlySpan.ofBytes(b, 0, 7)));
		trace(StringTools.hex(W.tail(ReadOnlySpan.ofBytes(b))), W.whole(ReadOnlySpan.ofBytes(b, 16)));
		trace(W.at(ReadOnlySpan.ofBytes(b), 18));
	}
}
