// No span of proofs: a span of bytes reinterpreted would forge them.
// expect: KernelProofSpan.hx:7: KernelProofSpan.forge: the local t is a span of proofs (kernel: a proof is made only by @:hxmc.unsafe code)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofSpan {
	@:hxmc.kernel static function forge(s:hxmc.Span<Int>):Int {
		var t:hxmc.Span<Index> = s.reinterpret();
		return t[0];
	}

	static function main()
		trace(forge(hxmc.Span.ofBytes(haxe.io.Bytes.alloc(8))));
}
