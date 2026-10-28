// Two declarations of a variadic C function agree on how many arguments are
// fixed (@:hxmc.varargs).
// expect: C function va_count is declared twice with different signatures
extern class A {
	@:hxmc.c @:hxmc.fast @:hxmc.varargs(1) static function va_count(n:Int, a:Int):Int;
}

extern class B {
	@:hxmc.c @:hxmc.fast @:hxmc.varargs(2) static function va_count(n:Int, a:Int, b:Int):Int;
}

class VarargsCount {
	static function main()
		trace(A.va_count(1, 2) + B.va_count(1, 2, 3));
}
