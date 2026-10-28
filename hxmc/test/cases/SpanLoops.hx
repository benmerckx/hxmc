import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// Element checks a loop proves, which the compiler drops (Opt.condProp;
// docs/interop.md, "Spans"): for (i in 0...s.length), 0...n with n tested
// against the length first (also through another span's equal length), a
// sub-span's loop, a while loop counting up, a table's index masked below a
// length tested first. And the ones it must keep, which still fail: a
// counter from a value that may be negative, a bound the length was not
// tested against. The last call starts at -1: the program ends (exit 2).
// The checks left in each kernel (Corpus: the Mir's calls of outOfRange):
// span-checks: L.sum=0 L.prefix=0 L.dot=0 L.middle=0 L.squares=1 L.crc=0 L.upTo=1 L.from=1
@:hxmc.kernel class L {
	public static function sum(s:ReadOnlySpan<UInt8>):Int {
		var t = 0;
		for (i in 0...s.length)
			t += s[i];
		return t;
	}

	public static function prefix(s:ReadOnlySpan<UInt8>, n:Int):Int {
		if (n > s.length) return -1;
		var t = 0;
		for (i in 0...n)
			t = t * 7 + s[i];
		return t;
	}

	public static function dot(ab:ReadOnlySpan<UInt8>, bb:ReadOnlySpan<UInt8>):Int {
		var a:ReadOnlySpan<Int> = ab.reinterpret(), b:ReadOnlySpan<Int> = bb.reinterpret();
		var n = a.length;
		if (b.length != n) return -1;
		var t = 0;
		for (i in 0...n)
			t += a[i] * b[i];
		return t;
	}

	public static function middle(s:ReadOnlySpan<UInt8>):Int {
		var m = s.sub(1, s.length - 2), t = 0;
		for (i in 0...m.length)
			t = t * 3 + m[i];
		return t;
	}

	public static function squares(s:Span<UInt8>):Int {
		var w:Span<Int> = s.reinterpret();
		var i = 0;
		while (i < w.length) {
			w[i] = i * i;
			i++;
		}
		return w[w.length - 1];
	}

	public static function crc(s:ReadOnlySpan<UInt8>, tb:ReadOnlySpan<UInt8>):Int {
		var t:ReadOnlySpan<Int> = tb.reinterpret();
		if (t.length < 256) return -1;
		var c = 0xFFFFFFFF;
		for (i in 0...s.length)
			c = t[(c ^ s[i]) & 0xFF] ^ (c >>> 8);
		return c ^ 0xFFFFFFFF;
	}

	// (kept: n is not tested against the length)
	public static function upTo(s:ReadOnlySpan<UInt8>, n:Int):Int {
		var t = 0;
		for (i in 0...n)
			t += s[i];
		return t;
	}

	// (kept: the counter starts where the caller says, maybe below 0)
	public static function from(s:ReadOnlySpan<UInt8>, start:Int):Int {
		var i = start, t = 0;
		while (i < s.length) {
			t += s[i];
			i++;
		}
		return t;
	}
}

class SpanLoops {
	static function main() {
		var b = Bytes.alloc(1000);
		for (i in 0...b.length)
			b.set(i, i * 7 + 3);
		var table = Bytes.alloc(1024);
		for (n in 0...256) {
			var c = n;
			for (k in 0...8)
				c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
			table.setInt32(n * 4, c);
		}
		trace("sum", L.sum(ReadOnlySpan.ofBytes(b)), L.sum(ReadOnlySpan.ofBytes(b, 10, 0)));
		trace("prefix", L.prefix(ReadOnlySpan.ofBytes(b), 9), L.prefix(ReadOnlySpan.ofBytes(b), 1001));
		trace("dot", L.dot(ReadOnlySpan.ofBytes(b, 0, 400), ReadOnlySpan.ofBytes(b, 400, 400)));
		trace("middle", L.middle(ReadOnlySpan.ofBytes(b, 0, 12)));
		var sq = Bytes.alloc(40);
		trace("squares", L.squares(Span.ofBytes(sq)), sq.getInt32(12));
		var text = Bytes.ofString("The quick brown fox jumps over the lazy dog");
		trace("crc", StringTools.hex(L.crc(ReadOnlySpan.ofBytes(text), ReadOnlySpan.ofBytes(table)), 8),
			StringTools.hex(haxe.crypto.Crc32.make(text), 8), L.crc(ReadOnlySpan.ofBytes(text), ReadOnlySpan.ofBytes(table, 0, 1020)));
		trace("kept", L.upTo(ReadOnlySpan.ofBytes(b), 5), L.from(ReadOnlySpan.ofBytes(b), 995));
		Sys.stdout().flush();
		trace(L.from(ReadOnlySpan.ofBytes(b), -1));
		trace("not reached");
	}
}
