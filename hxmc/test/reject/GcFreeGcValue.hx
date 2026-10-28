// A @:hxmc.gcfree function holds no value of a GC type: it may run while other threads collect.
// expect: GcFreeGcValue.f is declared @:hxmc.gcfree but its parameter s has a GC type
class GcFreeGcValue {
	@:hxmc.unsafe @:hxmc.gcfree static function f(s:String):Int
		return 1;

	static function main()
		trace(f("x"));
}
