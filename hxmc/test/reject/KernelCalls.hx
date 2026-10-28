// A @:hxmc.kernel function calls only @:hxmc.kernel (or @:hxmc.blocking) functions, not merely @:hxmc.unsafe ones.
// expect: KernelCalls.f is declared @:hxmc.kernel but it calls KernelCalls.g, which is not @:hxmc.kernel (nor @:hxmc.blocking)
class KernelCalls {
	@:hxmc.unsafe static function g(v:Int):Int
		return v * 2;

	@:hxmc.unsafe @:hxmc.kernel static function f(v:Int):Int
		return g(v) + 1;

	static function main()
		trace(f(1));
}
