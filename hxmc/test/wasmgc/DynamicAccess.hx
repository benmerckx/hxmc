// what the port does through Dynamic (GcCheck): statics through a class value
// (read, written, called), Reflect.copy, Std.isOfType with a type known at run
// time only (and Int of an integral Float), the methods of Arrays and Strings
// called through structural types and Dynamic, a call of a non-function
interface Shape {
	function area():Float;
}

class Square implements Shape {
	public var side:Float;

	public function new(side)
		this.side = side;

	public function area()
		return side * side;
}

class Big extends Square {}

class Reader {
	public static var count = 0;
	public static var label = "reader";

	public static function readIdent(s:String):String {
		count++;
		return s.toUpperCase();
	}

	public static function twice(x:Int):Int
		return 2 * x;
}

class DynamicAccess {
	static function check(v:Dynamic, t:Dynamic):Bool
		return Std.isOfType(v, t);

	static function all<T>(it:Iterable<T>, f:T->Bool):Bool {
		for (x in it)
			if (!f(x)) return false;
		return true;
	}

	static function main() {
		// statics through the class value
		var api:Dynamic = Reader;
		Sys.println(api.readIdent("on") + " " + api.twice(21) + " " + api.count + " " + api.label);
		api.count = 10;
		api.label = "changed";
		Sys.println(Reader.count + " " + Reader.label);
		try {
			Reflect.setField(Reader, "twice", null);
		} catch (e:Dynamic) {
			Sys.println("not rebound: " + e);
		}
		// Reflect.copy
		var o:Dynamic = {a: 1, b: "two"};
		o.c = 3.5;
		var c:Dynamic = Reflect.copy(o);
		c.a = 2;
		c.c = 4.5;
		Sys.println(o.a + " " + o.b + " " + o.c + " " + c.a + " " + c.b + " " + c.c);
		var sq = new Square(3);
		var sq2:Square = Reflect.copy(sq);
		sq2.side = 4;
		Sys.println(sq.area() + " " + sq2.area() + " " + (Reflect.copy(null) == null));
		// Std.isOfType with types known at run time
		var types:Array<Dynamic> = [Square, Big, Shape, String, Int, Float, Bool, Array, Dynamic, DynamicAccess];
		var values:Array<Dynamic> = [new Square(1), new Big(2), "s", 1, 2.0, 2.5, true, [1], null];
		for (v in values)
			Sys.println([for (t in types) check(v, t) ? "1" : "0"].join(""));
		var two:Dynamic = 2.0;
		Sys.println(Std.isOfType(two, Int) + " " + Std.isOfType(2.5, Int) + " " + (Std.downcast((new Big(1) : Square), Big) != null) + " " + (Std.downcast(new Square(1), Big) == null));
		// built-in methods through structural types and Dynamic
		Sys.println(all([1, 2, 3], x -> x > 0) + " " + all(["a", "b"], s -> s.length == 1) + " " + all([1.5, -1], x -> x > 0));
		var arr:Dynamic = [3, 1, 2];
		arr.push(4);
		arr.sort((a, b) -> a - b);
		var s:Dynamic = "Hello";
		Sys.println(arr.join("-") + " " + arr.indexOf(2) + " " + s.toUpperCase() + " " + s.charAt(1) + " " + s.split("l").length);
		// calling what is not a function
		var nf:Dynamic = null;
		try {
			nf(1);
		} catch (e:Dynamic) {
			Sys.println("caught: " + e);
		}
	}
}
