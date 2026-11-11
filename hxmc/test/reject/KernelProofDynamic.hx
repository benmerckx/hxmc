// A Dynamic is no proof: unboxed where one is expected, it would forge one.
// expect: KernelProofDynamic.hx:10: KernelProofDynamic.forge: a value of type Dynamic as the proof Index (kernel: a proof is made only by @:hxmc.unsafe code)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofDynamic {
	@:hxmc.kernel static function use(t:Index):Int
		return t;

	@:hxmc.kernel static function forge(d:Dynamic):Int {
		var t:Index = d;
		return use(t);
	}

	static function main()
		trace(forge(1));
}
