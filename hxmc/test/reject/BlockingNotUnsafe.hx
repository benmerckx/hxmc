// A @:hxmc.blocking Haxe function must be @:hxmc.unsafe (no allocation, no GC point).
// expect: BlockingNotUnsafe.f is declared @:hxmc.blocking but is not @:hxmc.unsafe
class BlockingNotUnsafe {
	@:hxmc.blocking static function f(v:Int):Int
		return v + 1;

	static function main()
		trace(f(1));
}
