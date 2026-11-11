package hxmc.rt;

import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// The runtime's reports for kernels (Os.Report's, over a span): a line
// built in a kernel's scratch, each function writing at `at` and returning
// where the line goes on (what passes the span's end is left out), then
// written to stderr (out, the one trusted part) or ended with (fatal):
//
//   var b:Span<UInt8> = Span.stack(128);
//   var n = Text.lit(b, 0, "hxmc: bad value ");
//   n = Text.int(b, n, v, 0);
//   Text.fatal(b, n, 2);
@:hxmc.kernel
class Text {
	public static function ch(b:Span<UInt8>, at:Int, c:Int):Int {
		if (at >= 0 && at < b.length) b[at] = c;
		return at + 1;
	}

	// a string's units (a literal: one byte each; another unit is '?')
	public static function lit(b:Span<UInt8>, at:Int, s:String):Int {
		if (StrView.isOne(s)) {
			var u = StrView.units1(s);
			for (i in 0...u.length)
				at = ch(b, at, u[i]);
		} else {
			var u = StrView.units2(s);
			for (i in 0...u.length)
				at = ch(b, at, (u[i] : Int) < 0x100 ? u[i] : "?".code);
		}
		return at;
	}

	// v in decimal, right-aligned in `width` (%Nld)
	public static function int(b:Span<UInt8>, at:Int, v:I64, width:Int):Int {
		var d:Span<UInt8> = Span.stack(24);
		var k = 0, neg = v < 0;
		do {
			var r = (v % 10).toInt();
			d[k++] = 48 + (r < 0 ? -r : r);
			v = v / 10;
		} while (!(v == 0) && k < 20);
		if (neg) d[k++] = "-".code;
		var w = k;
		while (w < width) {
			at = ch(b, at, " ".code);
			w++;
		}
		while (k > 0)
			at = ch(b, at, d[--k]);
		return at;
	}

	// b[0, n) to stderr (n within it)
	public static function out(b:ReadOnlySpan<UInt8>, n:Int)
		write(b.sub(0, n < b.length ? n : b.length));

	// the line, a new line, and the end of the program
	public static function fatal(b:Span<UInt8>, n:Int, code:Int) {
		n = ch(b, n, 10);
		out(b, n);
		exit(code);
	}

	// (the C library's write, the end of the program: Os's, Wasi's)
	@:hxmc.unsafe static function write(b:ReadOnlySpan<UInt8>) {
		#if (hxmc.target == "wasm32-wasi")
		hxmc.rt.wasm.Wasi.flush();
		hxmc.rt.wasm.Wasi.writeRaw(2, (cast b : hxmc.Span.SpanData).ptr, b.length);
		#else
		Os.write((cast b : hxmc.Span.SpanData).ptr, b.length);
		#end
	}

	@:hxmc.unsafe static function exit(code:Int) {
		#if (hxmc.target == "wasm32-wasi")
		hxmc.rt.wasm.Wasi.exit(code);
		#else
		Os.exit(code);
		#end
	}
}
