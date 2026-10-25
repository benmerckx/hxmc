// Literals that build scoped values where one is expected (docs/plans/lowlevel.md,
// "Less to write"): array literals as a Slice, a Grow or a Fixed; strings with
// interpolations as a Str.
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	static function sum(s:Slice<Int>):Int {
		var t = 0;
		for (v in s)
			t += v;
		return t;
	}

	public static function slices():Int {
		var s:Slice<Int> = [1, 2, 3];
		return sum(s) * 100 + sum([4, 5]) + s.length;
	}

	public static function grows():Float {
		var g:Grow<Float> = [0.5, 1.5];
		g.push(2);
		var t = 0.0;
		for (v in g)
			t += v;
		return t + g.length;
	}

	public static function fixeds():Float {
		var f:Fixed<Float, 3> = [1.25, 2.5, 5];
		var t = 0.0;
		for (v in f)
			t += v;
		return t;
	}

	// elements of struct values (anonymous structures too)
	public static function points():Int {
		var ps:Slice<{x:Int, y:Int}> = [{x: 1, y: 2}, {x: 3, y: 4}];
		return ps[0].x * 1000 + ps[0].y * 100 + ps[1].x * 10 + ps[1].y;
	}

	public static function text(n:Int, f:Float, ok:Bool, name:Str):Str
		return '$name: n=$n, f=$f, ok=$ok, sum=${n + 1}';

	public static function interpolated():Int {
		var s = text(41, 2.5, true, "it");
		return s.length;
	}
}

class ScopedLiterals {
	static function main() {
		trace(Code.slices());
		trace(Code.grows());
		trace(Code.fixeds());
		trace(Code.points());
		trace(Code.text(41, 2.5, true, "it").toString());
		trace(Code.interpolated());
	}
}
