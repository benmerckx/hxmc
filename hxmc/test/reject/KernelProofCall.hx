// GC code never passes a proof: it could make one from anything.
// expect: KernelProofCall.hx:10: KernelProofCall.main: a call of KernelProofCall.use, which takes a proof (kernel: a proof is made only by @:hxmc.unsafe code: only kernels and @:hxmc.unsafe code call a function taking one)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofCall {
	@:hxmc.kernel static function use(t:Index):Int
		return t;

	static function main()
		trace(use(cast 7));
}
