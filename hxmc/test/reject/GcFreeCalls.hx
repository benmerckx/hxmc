// A @:hxmc.gcfree function calls only @:hxmc.gcfree (or @:hxmc.blocking) functions, not merely @:hxmc.unsafe ones.
// expect: GcFreeCalls.f is declared @:hxmc.gcfree but it calls GcFreeCalls.g, which is not @:hxmc.gcfree (nor @:hxmc.blocking)
class GcFreeCalls {
	@:hxmc.unsafe static function g(v:Int):Int
		return v * 2;

	@:hxmc.unsafe @:hxmc.gcfree static function f(v:Int):Int
		return g(v) + 1;

	static function main()
		trace(f(1));
}
