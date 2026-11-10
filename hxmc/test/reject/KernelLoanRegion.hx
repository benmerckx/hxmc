// A kernel that enters a safe region holds no GC values: other threads collect meanwhile.
// expect: KernelLoanRegion.f is declared @:hxmc.kernel but its parameter s has a GC type (a kernel that enters a safe region holds no GC values)
class KernelLoanRegion {
	@:hxmc.unsafe @:hxmc.blocking static function wait(v:Int):Int
		return v;

	@:hxmc.kernel static function f(s:String):Int
		return wait(1);

	static function main()
		trace(f("x"));
}
