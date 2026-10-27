// A @:hxmc.blocking call cannot pass a GC reference either, even of a class declared @:hxmc.fast.
// expect: C function blocking_takes_string: parameter s has no C type a call can pass (a GC reference, which only a @:hxmc.fast call may take
@:hxmc.c @:hxmc.fast extern class C {
	@:hxmc.blocking static function blocking_takes_string(s:String):Int;
}

class BlockingGcType {
	static function main()
		trace(C.blocking_takes_string("x"));
}
