// Two declarations of a variadic C function may differ in their variadic
// arguments, not in their fixed ones.
// expect: C function va_fixed is declared twice with different signatures
extern class A {
	@:hxmc.c @:hxmc.fast @:hxmc.varargs(1) static function va_fixed(n:Int, a:Int):Int;
}

extern class B {
	@:hxmc.c @:hxmc.fast @:hxmc.varargs(1) static function va_fixed(n:hxmc.unsafe.Float32, a:Int, b:Int):Int;
}

class VarargsFixed {
	static function main()
		trace(A.va_fixed(1, 2) + B.va_fixed(1, 2, 3));
}
