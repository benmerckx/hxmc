// A Dynamic converted to a function type and back (upstream's
// unit.issues.Issue12028): Reflect.makeVarArgs's function typed by
// inference as String -> String keeps every argument of a later dynamic
// call (Reflect.callMethod, a call through Dynamic, through a field); the
// adapter a Dynamic gets as a function (Lower.dynAdapter) is not what a
// dynamic call calls (Dyn.unadapt). The output is the reference's (--interp).
class VarArgsThroughType {
	static function foo(func:Dynamic):Dynamic
		return func("b", "c");

	static function viaField(o:Dynamic):Dynamic
		return o.f(1, 2, 3);

	static function typed(f:Int->Int):Int
		return f(5);

	static function main() {
		var func = function(args:Array<Dynamic>):String {
			return args.length + ":" + args.join(",");
		};
		var f2 = Reflect.makeVarArgs(func);
		trace(f2("a"));
		trace(foo(f2));
		trace(Reflect.callMethod(null, f2, ["d", "e", "f"]));
		trace(Reflect.callMethod(null, f2, []));
		var d:Dynamic = f2;
		trace(d());
		trace(d(1, 2));
		trace(viaField({f: f2}));
		trace(Reflect.isFunction(f2));
		// (a function of its own arity, converted and back)
		var add:Dynamic = (a:Int, b:Int) -> a + b;
		var add1:Int->Int = add;
		var back:Dynamic = add1;
		trace(back(3, 4));
		trace(Reflect.callMethod(null, back, [10, 20]));
		// (twice through types)
		var g:Dynamic = Reflect.makeVarArgs(a -> a.length);
		var g1:String->Int = g;
		var g2:Dynamic = g1;
		var g3:(Int, Int) -> Int = g2;
		var g4:Dynamic = g3;
		trace(g1("x") + " " + g3(1, 2) + " " + g4(1, 2, 3, 4));
		trace(typed(Reflect.makeVarArgs(a -> a[0] * 2)));
	}
}
