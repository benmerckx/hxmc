// Scoped functions take function values only when inline (compile-time function values, no closures at run time).
// expect: ScopedFunctionParam.hx:6: Code.each: the parameter f is a function: scoped functions take function values only when inline
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function each(n:Int, f:Int->Void)
		for (i in 0...n) f(i);

}

class ScopedFunctionParam {
	static function main()
		Code.each(3, i -> trace(i));
}
