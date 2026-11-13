// A function taking a proof is no value: called dynamically, it would take anything.
// expect: KernelProofValue.hx:11: KernelProofValue.main: KernelProofValue.use as a value, which takes a proof (kernel: a proof is made only by @:hxmc.unsafe code: a function taking one is no value)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofValue {
	@:hxmc.kernel static function use(t:Index):Int
		return t;

	static function main() {
		var f:Dynamic = null;
		f = use;
		trace(f(7));
	}
}
