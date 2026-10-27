// A call cannot be both @:hxmc.blocking and @:hxmc.fast.
// expect: C function both_ways is declared both @:hxmc.blocking and @:hxmc.fast
extern class C {
	@:hxmc.c @:hxmc.blocking @:hxmc.fast static function both_ways(v:Int):Int;
}

class BlockingAndFast {
	static function main()
		trace(C.both_ways(1));
}
