// A C function needs @:hxmc.unsafe: C reaches memory unchecked.
// expect: GcFreeCFunction.hx:9: GcFreeCFunction.magnitude: a call of C.abs (gcfree: Mem, Atomic and C functions need @:hxmc.unsafe)
@:hxmc.c @:hxmc.fast extern class C {
	static function abs(v:Int):Int;
}

class GcFreeCFunction {
	@:hxmc.gcfree static function magnitude(v:Int):Int
		return C.abs(v);

	static function main()
		trace(magnitude(-3));
}
