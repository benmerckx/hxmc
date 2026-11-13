// No static holds a proof: GC code writes statics.
// expect: KernelProofStatic.hx:6: the static last is a proof (kernel: a proof is made only by @:hxmc.unsafe code: no static holds one)
@:hxmc.proof abstract Index(Int) to Int {}

class KernelProofStatic {
	static var last:Index;

	@:hxmc.kernel static function get():Int
		return last;

	static function main()
		trace(get());
}
