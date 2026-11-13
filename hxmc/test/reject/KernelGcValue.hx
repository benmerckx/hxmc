// A kernel's GC values are loans: kept in locals, never stored (it has no write barrier).
// expect: KernelGcValue.f is declared @:hxmc.kernel but it stores a GC value
class KernelGcValue {
	static var last:String;

	@:hxmc.unsafe @:hxmc.kernel static function f(s:String):Int {
		last = s;
		return 1;
	}

	static function main()
		trace(f("x"));
}
