// A proof is made only by @:hxmc.unsafe code: a safe kernel cannot cast an Int to one.
// expect: KernelProofCast.hx:13: KernelProofCast.forge: a cast from Int to the proof Index (kernel: a proof is made only by @:hxmc.unsafe code)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofCast {
	@:hxmc.unsafe @:hxmc.kernel static function make(i:Int):Index
		return cast(i & 3);

	@:hxmc.kernel static function use(t:Index):Int
		return t;

	@:hxmc.kernel static function forge(i:Int):Int
		return use(cast i);

	@:hxmc.kernel static function ok(i:Int):Int
		return use(make(i));

	static function main()
		trace(forge(1) + ok(2));
}
