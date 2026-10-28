// Nor a call through a closure: its callee is unknown, so unchecked.
// expect: KernelClosureCall.hx:5: KernelClosureCall.apply: the parameter f is a function (kernel: no closures)
// expect: KernelClosureCall.hx:6: KernelClosureCall.apply: a call through a closure or a structural field (kernel: calls only static kernels)
class KernelClosureCall {
	@:hxmc.kernel static function apply(f:Int->Int, v:Int):Int
		return f(v);

	static function main()
		trace(apply(x -> x + 1, 1));
}
