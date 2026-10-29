// A C function needs @:hxmc.unsafe: C reaches memory unchecked.
// expect: KernelCFunction.hx:9: KernelCFunction.magnitude: a call of C.abs (kernel: Mem, Atomic and C functions need @:hxmc.unsafe)
@:hxmc.c @:hxmc.fast extern class C {
	static function abs(v:Int):Int;
}

class KernelCFunction {
	@:hxmc.kernel static function magnitude(v:Int):Int
		return C.abs(v);

	static function main()
		trace(magnitude(-3));
}
