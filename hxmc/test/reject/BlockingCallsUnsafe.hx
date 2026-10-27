// A @:hxmc.blocking function calls only other @:hxmc.blocking functions (and fast or blocking C).
// expect: BlockingCallsUnsafe.f is declared @:hxmc.blocking but it calls BlockingCallsUnsafe.g, which is not @:hxmc.blocking
class BlockingCallsUnsafe {
	@:hxmc.unsafe static function g(v:Int):Int
		return v * 2;

	@:hxmc.unsafe @:hxmc.blocking static function f(v:Int):Int
		return g(v) + 1;

	static function main()
		trace(f(1));
}
