// An abstract over a proof is one: a cast to it forges the proof inside.
// expect: KernelProofWrap.hx:11: KernelProofWrap.forge: a cast from Int to the proof Wrap (kernel: a proof is made only by @:hxmc.unsafe code)
@:hxmc.proof abstract Index(Int) to Int {}
abstract Wrap(Index) to Index {}

class KernelProofWrap {
	@:hxmc.kernel static function use(t:Index):Int
		return t;

	@:hxmc.kernel static function forge(i:Int):Int {
		var w:Wrap = cast i;
		return use(w);
	}

	static function main()
		trace(forge(1));
}
