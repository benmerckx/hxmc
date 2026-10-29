// A @:hxmc.kernel function holds no value of a GC type: it may run while other threads collect.
// expect: KernelGcValue.f is declared @:hxmc.kernel but its parameter s has a GC type
class KernelGcValue {
	@:hxmc.unsafe @:hxmc.kernel static function f(s:String):Int
		return 1;

	static function main()
		trace(f("x"));
}
