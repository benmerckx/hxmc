// Reflect.makeVarArgs (upstream's unit tests TestMisc, Issue2937, Issue9037,
// Issue12028): hxmc threw "not supported"; the function it makes takes any
// number of arguments in a dynamic call, Reflect.callMethod and through a
// function type.
class MakeVarArgs {
	static function call(f:Dynamic):Dynamic
		return f("b", "c");

	static function main() {
		var g:Dynamic = Reflect.makeVarArgs(function(a:Array<Dynamic>) return a.length == 0 ? 0 : a[0] + a[a.length - 1]);
		Sys.println(g(1, 2));
		Sys.println(g(5));
		Sys.println(g());
		var s:Dynamic = Reflect.makeVarArgs(function(args:Array<Dynamic>):String return args.length >= 1 ? args.join("+") : "");
		Sys.println(s("a"));
		Sys.println(call(s));
		Sys.println(Reflect.callMethod(null, s, ["d", "e", "f"]));
		var count = 0;
		var v:Dynamic = Reflect.makeVarArgs(function(args:Array<Dynamic>) {
			count += args.length;
			Sys.println((args is Array) + " " + args.length);
		});
		v();
		v(1, 2, 3);
		var typed:(Int, Int) -> Dynamic = Reflect.makeVarArgs(function(a:Array<Dynamic>) return a.length);
		Sys.println(typed(4, 5) + " " + count);
		Sys.println(Reflect.isFunction(s));
	}
}
