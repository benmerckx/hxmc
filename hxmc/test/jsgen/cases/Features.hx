// what a chunk's code needs of the generated code around it: interfaces
// and their checks, closures ($bind), iterators, exceptions, reflection,
// static initialization, __init__, a split called from a chunk's class
interface Shape {
	function area():Float;
}

class Square implements Shape {
	public var side:Float;

	public function new(s) side = s;

	public function area() return side * side;
}

class Registry {
	public static var names:Array<String> = ["first"];
	public static var count = names.length;

	static function __init__() {
		trace("Registry init");
	}

	public static function add(n:String) {
		names.push(n);
		count = names.length;
	}
}

class Lazy {
	public var items = [3, 1, 2];

	public function new() {}

	public function sorted() {
		var copy = items.copy();
		copy.sort(Reflect.compare);
		return copy;
	}

	// (a keyword of strict code as a name: escaped in a split file too)
	public static function twice(yield:Int) return yield * 2;

	public function later() {
		// a split called from a type of a chunk
		var self = this;
		return js.Bundle.split("later", () -> {
			trace("later sees " + self.sorted());
			return new LaterOnly().value;
		});
	}
}

class LaterOnly {
	public var value = "only later";

	public function new() {}
}

class MyError extends haxe.Exception {}

class Features {
	static function main() {
		var shapes:Array<Shape> = [new Square(2)];
		js.Bundle.split("features", () -> {
			// interface check against a type of main
			var s:Dynamic = shapes[0];
			trace(Std.isOfType(s, Shape) + " " + shapes[0].area());
			// a closure of a method ($bind)
			var l = new Lazy();
			var f = l.sorted;
			trace(f());
			trace(Lazy.twice(21));
			// iteration
			var total = 0;
			for (x in l.items) total += x;
			var m = ["a" => 1, "b" => 2];
			for (k => v in m) total += v;
			trace("total " + total);
			// static initialization and __init__ in the chunk
			Registry.add("second");
			trace(Registry.names + " " + Registry.count);
			// exceptions
			try {
				throw new MyError("boom");
			} catch (e:MyError) {
				trace("caught " + e.message);
			}
			// reflection
			trace(Type.getClassName(Type.getClass(l)) + " " + (Type.resolveClass("Lazy") != null));
			return l.later();
		}).then(v -> trace("done: " + v));
	}
}
