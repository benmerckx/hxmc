// Std.isOfType, Std.downcast and cast with a class literal: the instance
// test (FnLower.instClass: EInstOf, a range of type indices) where the class
// is the program's, hx_is for interfaces and the runtime's types. Each
// value is tested typed and as Dynamic; null is an instance of nothing and
// casts to null. The output is the reference's (--interp).
interface Named {
	function name():String;
}

class Base {
	public var x:Int;

	public function new(x:Int)
		this.x = x;
}

class Mid extends Base implements Named {
	public function name()
		return "mid" + x;
}

class Leaf extends Mid {}
class Other extends Base {}

abstract class Shape {
	public function new() {}

	public abstract function area():Float;
}

class Square extends Shape {
	var s:Float;

	public function new(s:Float) {
		super();
		this.s = s;
	}

	public function area()
		return s * s;
}

class Box<T> {
	public var v:T;

	public function new(v:T)
		this.v = v;
}

enum E {
	A;
	B(i:Int);
}

class InstanceOf {
	static function kinds(v:Dynamic):String {
		return [
			Std.isOfType(v, Base), Std.isOfType(v, Mid), Std.isOfType(v, Leaf), Std.isOfType(v, Other), Std.isOfType(v, Named),
			Std.isOfType(v, Shape), Std.isOfType(v, Square), Std.isOfType(v, Box), Std.isOfType(v, String), Std.isOfType(v, Int),
			Std.isOfType(v, Array), Std.isOfType(v, InstanceOf)
		].map(b -> b ? "1" : "0").join("");
	}

	static function typed(b:Base):String {
		var m = Std.downcast(b, Mid);
		var l = Std.downcast(b, Leaf);
		return (Std.isOfType(b, Mid) ? "M" : "-") + (Std.isOfType(b, Leaf) ? "L" : "-") + (Std.isOfType(b, Other) ? "O" : "-")
			+ " " + (m == null ? "null" : m.name()) + " " + (l == null ? "null" : l.name());
	}

	static function tryCast(v:Dynamic):String {
		try {
			var m = cast(v, Mid);
			return m == null ? "null" : m.name();
		} catch (e:Dynamic) {
			return "error " + e;
		}
	}

	static function main() {
		var values:Array<Dynamic> = [
			null, new Base(1), new Mid(2), new Leaf(3), new Other(4), new Square(2), new Box(1), new Box("s"), "str", 5, 2.5, true, [1, 2], {x: 1},
			A, B(1), Base, function() {}, new InstanceOf()
		];
		for (v in values)
			trace(kinds(v) + " " + tryCast(v));
		var bs:Array<Base> = [null, new Base(1), new Mid(2), new Leaf(3), new Other(4)];
		for (b in bs)
			trace(typed(b));
		// a downcast of a value with side effects evaluates it once
		var n = 0;
		function next():Base {
			n++;
			return bs[n % bs.length];
		}
		var got = [for (_ in 0...5) Std.downcast(next(), Mid)].map(m -> m == null ? "-" : m.name());
		trace(got.join(",") + " " + n);
		// a typed cast of a subclass
		var s:Shape = new Square(3);
		trace(cast(s, Square).area() + " " + Std.downcast(s, Square).area());
		var o:Base = new Other(7);
		trace(Std.downcast(o, Mid) == null);
	}

	public function new() {}
}
