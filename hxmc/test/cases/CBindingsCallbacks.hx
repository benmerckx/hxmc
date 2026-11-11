import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.*;

// Typed callbacks (docs/interop.md, "Typed callbacks"): C calls checked
// kernels whose out-parameters and struct pointers are spans its wrapper
// makes from C's addresses (@:hxmc.len: a constant, or a sibling
// parameter), as DirectWrite's IDWriteTextAnalysisSource and Sink are
// called: GetTextAtPosition(pos, out text, out len), SetScriptAnalysis(pos,
// len, const DWRITE_SCRIPT_ANALYSIS *). The objects' own memory (self) is
// a span of their size too. CBindingsCallbacks.c is the analyzer.
@:hxmc.struct @:hxmc.cname("struct cb_analysis") @:publicFields class Analysis {
	var script:UInt16;
	var shapes:Int32;
}

@:hxmc.c @:hxmc.header("CBindingsCallbacks.h") extern class Lib {
	static function cb_analyze(source:Ptr, textAt:(Span<Int>, Int, Span<I64>, Span<Int>) -> Int, sink:Ptr,
		setScript:(Span<Int>, Int, Int, ReadOnlySpan<Analysis>) -> Int):Int;
}

class CBindingsCallbacks {
	// the source: the text's address (a word), its length; at most 4 units a time
	@:hxmc.callback @:hxmc.kernel @:hxmc.len(self, 4) @:hxmc.len(text, 1) @:hxmc.len(len, 1)
	static function textAt(self:Span<Int>, pos:Int, text:Span<I64>, len:Span<Int>):Int {
		var n = self[2];
		var k = n - pos < 4 ? n - pos : 4;
		len[0] = k < 0 ? 0 : k;
		// (an address computed for C: the source's own text, which C reads)
		text[0] = self.getI64(0) + 2 * pos;
		return 0;
	}

	// the sink: runs, then units of script 25 and of other scripts
	@:hxmc.callback @:hxmc.kernel @:hxmc.len(self, 4) @:hxmc.len(a, 1)
	static function setScript(self:Span<Int>, pos:Int, len:Int, a:ReadOnlySpan<Analysis>):Int {
		self[0] += 1;
		if (a[0].script == 25) self[1] += len else self[2] += len;
		return 0;
	}

	static function main() {
		var s = "héllo wörld мир, ok";
		var text = IoBuffer.alloc(2 * s.length), source = IoBuffer.alloc(16), sink = IoBuffer.alloc(16);
		for (i in 0...s.length) {
			text.set(2 * i, s.charCodeAt(i) & 0xFF);
			text.set(2 * i + 1, s.charCodeAt(i) >> 8);
		}
		source.setI64(0, text.ptr.toI64());
		source.setInt32(8, s.length);
		trace(Lib.cb_analyze(source.ptr, textAt, sink.ptr, setScript));
		trace(sink.getInt32(0), sink.getInt32(4), sink.getInt32(8));
		text.free();
		source.free();
		sink.free();
	}
}
