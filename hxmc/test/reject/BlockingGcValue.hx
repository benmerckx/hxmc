// A @:hxmc.blocking function holds no value of a GC type: it runs while other threads collect.
// expect: BlockingGcValue.f is declared @:hxmc.blocking but its parameter s has a GC type
class BlockingGcValue {
	@:hxmc.unsafe @:hxmc.blocking static function f(s:String):Int
		return 1;

	static function main()
		trace(f("x"));
}
