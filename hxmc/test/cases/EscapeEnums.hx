// Escape analysis (hxmc/src/hxmc/Escape.hx): enum values matched where they
// are made (their tag is known, the switch folds, the value goes), and boxed
// numbers unboxed where they are boxed. Each function prints what it
// computes, the same whether the value stays or goes.
import haxe.ds.Option;

enum Shape {
	Circle(r:Float);
	Rect(w:Int, h:Int);
	Named(name:String, inner:Shape);
	Empty;
}

class EscapeEnums {
	static var saved:Shape;

	static function some(x:Int):Option<Int>
		return x > 0 ? Some(x) : None;

	static function rect(w:Int, h:Int):Shape
		return Rect(w, h);

	static function area(s:Shape):Float
		return switch s {
			case Circle(r): r * r * 3;
			case Rect(w, h): w * h;
			case Named(_, i): -1;
			case Empty: 0;
		}

	// replaced: the constructor's tag folds the switch
	@:noinline static function matchRect(w:Int):Float {
		return area(rect(w, w + 1));
	}

	@:noinline static function matchCircle(r:Float):Float {
		var s = Circle(r);
		return area(s) + Type.enumIndex(s);
	}

	// kept: a constructor without arguments is a static value, the phi merges it
	@:noinline static function option(x:Int):Int {
		return switch some(x) {
			case Some(v): v * 2;
			case None: -1;
		}
	}

	// kept: two constructors meet at a phi
	@:noinline static function either(c:Bool, x:Int):Float {
		var s = c ? Circle(x) : Rect(x, 2);
		return area(s);
	}

	// kept: stored
	@:noinline static function stored(x:Int):Float {
		var s = Rect(x, x);
		saved = s;
		return area(s);
	}

	// kept: its parameters read by reflection
	@:noinline static function reflected(x:Int):Int {
		var s = Rect(x, 3);
		return Type.enumParameters(s).length + Type.enumIndex(s);
	}

	// an enum value inside another one: the inner one is stored, kept
	@:noinline static function nestedEnum(x:Int):Float {
		var s = Named("n", Rect(x, 1));
		return switch s {
			case Named(n, Rect(w, h)): w * h + n.length;
			case _: 0;
		}
	}

	// boxes: unboxed where they are made, in a loop, through a phi
	@:noinline static function boxInt(x:Int):Int {
		var d:Dynamic = x;
		var n:Null<Int> = x * 3;
		return d + n;
	}

	@:noinline static function boxFloat(x:Float):Float {
		var n:Null<Float> = x;
		var m:Null<Float> = x * 2;
		return n * m;
	}

	@:noinline static function boxLoop(k:Int):Int {
		var n:Null<Int> = 0;
		for (i in 0...k)
			n = n + i;
		return n;
	}

	@:noinline static function boxPhi(c:Bool, x:Int):Float {
		var n:Null<Int> = c ? x : x + 1000;
		return n + 0.5;
	}

	// kept: a box's identity, a box given away
	@:noinline static function boxEscapes(x:Int):String {
		var d:Dynamic = x * 1000;
		var e:Dynamic = x * 1000;
		return (d == e) + " " + Std.string(d);
	}

	// kept: a boxed Int read as a Float and back
	@:noinline static function boxNull(c:Bool):String {
		var n:Null<Int> = c ? 5 : null;
		return n == null ? "null" : "" + (n + 1);
	}

	static function main() {
		Sys.println(matchRect(4));
		Sys.println(matchCircle(2));
		Sys.println(option(21) + " " + option(-1));
		Sys.println(either(true, 2) + " " + either(false, 2));
		Sys.println(stored(5) + " " + saved.getName());
		Sys.println(reflected(7));
		Sys.println(nestedEnum(6));
		Sys.println(boxInt(5));
		Sys.println(boxFloat(1.5));
		Sys.println(boxLoop(100));
		Sys.println(boxPhi(true, 1) + " " + boxPhi(false, 1));
		Sys.println(boxEscapes(3));
		Sys.println(boxNull(true) + " " + boxNull(false));
	}
}
