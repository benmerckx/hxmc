package scopedpkg;

import hxmc.scoped.*;

// No metadata: scoped by the package (ScopedDefaults: -D hxmc.scoped-packages=scopedpkg)
class V2 {
	public var x:Float;
	public var y:Float;

	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

class Geo {
	// object literals make V2s (as for @:structInit)
	public static function walk(n:Int):Float {
		var g = new Grow<V2>();
		for (i in 0...n)
			g.push({x: i, y: 1});
		var t = 0.0;
		for (v in g)
			t += v.x * v.y;
		return t;
	}

	// a value: a copy is another V2
	public static function copies():Float {
		var a:V2 = {x: 1, y: 2};
		var b = a;
		b.x = 5;
		return a.x + b.x;
	}
}
