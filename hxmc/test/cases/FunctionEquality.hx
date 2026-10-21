// Closures of one method and object made apart are equal, as on Eval and hl
// (upstream's unit tests Issue6705, Issue12746: hxmc compared the closure
// objects); and Std.string of a structure with a toString field calls it
// (TestMisc).
class Base {}

class Sub extends Base {}

class Foo {
	public var n:Int;

	public function new(n)
		this.n = n;

	public function get()
		return n;

	public function onEvent(e:Sub):Void {}
}

class FunctionEquality {
	@:pure(false) static function alias<T>(t:T)
		return t;

	@:pure(false) static function equalsT<T>(a:T, b:T)
		return a == b;

	static function main() {
		var a = new Foo(1), b = new Foo(2);
		var g = a.get;
		Sys.println((a.get == alias(a.get)) + " " + (a.get == alias(g)) + " " + (g == a.get) + " " + (a.get == b.get));
		Sys.println(equalsT(a.get, a.get) + " " + equalsT(a.get, b.get));
		var x:Base->Void = cast a.onEvent;
		var y:Base->Void = cast a.onEvent;
		Sys.println(x == y);
		var arr = [a.get, b.get];
		Sys.println(arr.indexOf(b.get) + " " + arr.indexOf(a.get));
		var d:Dynamic = a.get;
		Sys.println(d == a.get);
		var o = {toString: function() return "foo"};
		Sys.println(Std.string(o) + " " + [o]);
	}
}
