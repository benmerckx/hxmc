// Nor a call through a closure: its callee is unknown, so unchecked.
// expect: GcFreeClosureCall.hx:5: GcFreeClosureCall.apply: the parameter f is a function (gcfree: no closures)
// expect: GcFreeClosureCall.hx:6: GcFreeClosureCall.apply: a call through a closure or a structural field (gcfree: calls only static GC-free functions)
class GcFreeClosureCall {
	@:hxmc.gcfree static function apply(f:Int->Int, v:Int):Int
		return f(v);

	static function main()
		trace(apply(x -> x + 1, 1));
}
