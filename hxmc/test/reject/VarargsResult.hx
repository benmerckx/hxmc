// Two declarations of a variadic C function agree on the result.
// expect: C function va_result is declared twice with different signatures
extern class A {
	@:hxmc.c @:hxmc.fast @:hxmc.varargs(1) static function va_result(n:Int, a:Int):Int;
}

extern class B {
	@:hxmc.c @:hxmc.fast @:hxmc.varargs(1) static function va_result(n:Int, a:Int, b:Int):Bool;
}

class VarargsResult {
	static function main()
		trace(A.va_result(1, 2) + ":" + B.va_result(1, 2, 3));
}
