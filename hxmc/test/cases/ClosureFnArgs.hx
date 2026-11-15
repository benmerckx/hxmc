// A function passed to a function value (a closure, a static's or a
// method's closure) where that value's type declares a function type of
// another signature than the function's own (one returning Int where
// Dynamic is declared): converted to the declared type at the call, as a
// direct call converts it, not passed as it is (the closure's signature,
// interned by its key, has Dynamic there): the callee read it through a
// dynamic adapter at every call.
typedef P = (x:Int, a:Array<Dynamic>) -> Dynamic;
typedef Reg = (name:String, f:P) -> Void;
typedef Pred = (x:Float) -> Null<Bool>;

class ClosureFnArgs {
	static var table:Array<P> = [];
	static var names:Array<String> = [];

	static function add(name:String, f:P) {
		names.push(name);
		table.push(f);
	}

	static function reg(r:Reg)
		r("through a static's closure", (x, a) -> x + a.length);

	static function apply(f:(Pred, Float) -> String, p:Pred, x:Float):String
		return f(p, x);

	static function main() {
		add("direct", (x, a) -> x * 2);
		reg(add);
		var r = (n:String, f:P) -> add(n, f);
		r("through a local closure", (x, a) -> x - a.length);
		r("a Float", (x, a) -> x / 2);
		r("a Bool", (x, a) -> x > 1);
		r("Dynamic", (x, a) -> (a : Dynamic));
		var o = {reg: add};
		o.reg("through a structure's field", (x, a) -> x + 100);
		for (k in 0...table.length)
			trace(names[k], table[k](3, [1, 2]), table[k] == table[k]);
		var show = (p:Pred, x:Float) -> Std.string(p(x));
		trace(apply(show, x -> x > 0, 1.5), apply(show, x -> null, 0), apply(show, x -> x < 0, 2));
		// (the same function passed twice: two adapters, each called)
		var same = (x:Int, a:Array<Dynamic>) -> x;
		r("same 1", same);
		r("same 2", same);
		trace(table[table.length - 2](7, []), table[table.length - 1](8, []));
	}
}
