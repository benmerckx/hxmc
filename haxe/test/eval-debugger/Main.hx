class Point {
	public var x:Int;
	public var y:Float;

	public function new(x, y) {
		this.x = x;
		this.y = y;
	}

	public function sum() {
		var s = x + y;
		return s;
	}
}

enum Color {
	Red;
	Rgb(r:Int, g:Int, b:Int);
}

class Main {
	static var counter = 3;

	static function helper(a:Int, b:String) {
		var c = a * 2;
		var d = b + "!";
		return c + d.length;
	}

	static function main() {
		var arr = [1, 2, 3];
		var p = new Point(4, 5.5);
		var col = Rgb(1, 2, 3);
		var o = {name: "obj", value: 42};
		var m = ["a" => 1, "b" => 2];
		var f = function(z:Int) return z + counter + arr.length;
		var r = helper(arr.length, "h\u00e9\u{1F600}");
		var t = p.sum() + f(r);
		trace(r, t, col, o, m);
		try {
			throw "oops";
		} catch (e:String) {
			trace(e);
		}
		for (i in 0...2) {
			counter += i;
		}
		var bytes = haxe.io.Bytes.ofString("hello");
		trace(counter, bytes.length);
		throw "uncaught";
	}
}
