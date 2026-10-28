// define: hxmc.span-checks=0
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// -D hxmc.span-checks=0 (docs/interop.md, "Spans"): a span's element
// accesses are not checked (as Burst's release builds); its ranges still
// are: a sub-view out of range ends the program (exit 2) as with the checks.
class SpanChecksOff {
	@:hxmc.kernel static function sum(s:ReadOnlySpan<UInt8>):Int {
		var t = 0;
		for (i in 0...s.length)
			t += s[i];
		return t;
	}

	@:hxmc.kernel static function twice(s:Span<UInt8>):Int {
		for (i in 0...s.length)
			s[i] = s[i] * 2;
		return sum(s);
	}

	@:hxmc.kernel static function cut(s:ReadOnlySpan<UInt8>, p:Int, n:Int):Int
		return sum(s.sub(p, n));

	static function main() {
		var b = haxe.io.Bytes.ofString("abcdef");
		trace(sum(ReadOnlySpan.ofBytes(b)), twice(Span.ofBytes(b)), b.toHex());
		trace(cut(ReadOnlySpan.ofBytes(b), 1, 5));
		Sys.stdout().flush();
		trace(cut(ReadOnlySpan.ofBytes(b), 2, 5));
	}
}
