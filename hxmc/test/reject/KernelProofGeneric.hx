// A kernel's type parameter result is any type: no proof comes from it (conv<T>(x:Dynamic):T would make one of anything).
// expect: KernelProofGeneric.hx:10: KernelProofGeneric.forge: a value of type conv.T as the proof Index (kernel: a proof is made only by @:hxmc.unsafe code)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofGeneric {
	@:hxmc.kernel static function conv<T>(x:Dynamic):T
		return x;

	@:hxmc.kernel static function forge(d:Dynamic):Int {
		var t:Index = conv(d);
		return t;
	}

	static function main()
		trace(forge(1));
}
