// Objects in the frame (hxmc/src/hxmc/FrameAlloc.hx): a class instance of
// scalar fields that only callees which do not retain it see lives in its
// function's frame (FuncInfo.retains); one a callee keeps (a static, an
// array, a return, a closure) stays in the heap. Collections run while
// frame objects are live (the collector leaves them alone), and a site in
// a loop makes a new object each round.
class V {
	public var x:Float;
	public var y:Float;
	public var n:Int;

	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
		n = 0;
	}
}

class FrameObjects {
	static var kept:V;
	static var all:Array<V> = [];

	// (each too big to inline: the padding)
	@:noinline static function len2(v:V):Float {
		var s = 0.0;
		var q = v.n;
		if (q == 100) q++;
		if (q == 101) q++;
		if (q == 102) q++;
		if (q == 103) q++;
		if (q == 104) q++;
		if (q == 105) q++;
		if (q == 106) q++;
		if (q == 107) q++;
		if (q == 108) q++;
		if (q == 109) q++;
		if (q == 110) q++;
		if (q == 111) q++;
		if (q == 112) q++;
		if (q == 113) q++;
		if (q == 114) q++;
		if (q == 115) q++;
		if (q == 116) q++;
		if (q == 117) q++;
		if (q == 118) q++;
		if (q == 119) q++;
		if (q == 120) q++;
		if (q == 121) q++;
		if (q == 122) q++;
		if (q == 123) q++;
		for (i in 0...2)
			s += v.x * v.x + v.y * v.y;
		return s / 2;
	}

	@:noinline static function scale(v:V, k:Float) {
		var q = v.n;
		if (q == 100) q++;
		if (q == 101) q++;
		if (q == 102) q++;
		if (q == 103) q++;
		if (q == 104) q++;
		if (q == 105) q++;
		if (q == 106) q++;
		if (q == 107) q++;
		if (q == 108) q++;
		if (q == 109) q++;
		if (q == 110) q++;
		if (q == 111) q++;
		if (q == 112) q++;
		if (q == 113) q++;
		if (q == 114) q++;
		if (q == 115) q++;
		if (q == 116) q++;
		if (q == 117) q++;
		if (q == 118) q++;
		if (q == 119) q++;
		if (q == 120) q++;
		if (q == 121) q++;
		if (q == 122) q++;
		if (q == 123) q++;
		for (i in 0...1)
			v.x *= k;
		v.y *= k;
		v.n++;
	}

	// (passes it on: as len2, it retains nothing)
	@:noinline static function twice(v:V):Float {
		var s = 0.0;
		var q = v.n;
		if (q == 100) q++;
		if (q == 101) q++;
		if (q == 102) q++;
		if (q == 103) q++;
		if (q == 104) q++;
		if (q == 105) q++;
		if (q == 106) q++;
		if (q == 107) q++;
		if (q == 108) q++;
		if (q == 109) q++;
		if (q == 110) q++;
		if (q == 111) q++;
		if (q == 112) q++;
		if (q == 113) q++;
		if (q == 114) q++;
		if (q == 115) q++;
		if (q == 116) q++;
		if (q == 117) q++;
		if (q == 118) q++;
		if (q == 119) q++;
		if (q == 120) q++;
		if (q == 121) q++;
		if (q == 122) q++;
		if (q == 123) q++;
		for (i in 0...2)
			s += len2(v);
		return s;
	}

	@:noinline static function keep(v:V) {
		for (i in 0...1)
			kept = v;
	}

	@:noinline static function push(v:V) {
		for (i in 0...1)
			all.push(v);
	}

	@:noinline static function same(v:V):V {
		for (i in 0...1)
			v.n += 10;
		return v;
	}

	@:noinline static function churn(k:Int):Int {
		var s = 0;
		for (i in 0...k)
			s += [i, i + 1].length;
		return s;
	}

	static function main() {
		var v = new V(3, 4);
		var c = churn(20000);
		Sys.println('len2: ${len2(v)} $c');
		scale(v, 2);
		churn(20000);
		Sys.println('scaled: ${v.x} ${v.y} ${v.n} ${twice(v)}');
		var t = 0.0;
		for (i in 0...1000) {
			var w = new V(i, 1);
			scale(w, 0.5);
			t += len2(w) + w.n;
			if (i % 100 == 0) churn(1000);
		}
		Sys.println('loop: $t');
		// (kept, pushed, returned: in the heap, read after their maker returned)
		make();
		churn(50000);
		Sys.println('kept: ${kept.x} ${kept.y}; pushed: ${all.length} ${all[0].x} ${all[1].y}; same: ${made.n}');
	}

	static var made:V;

	static function make() {
		keep(new V(5, 6));
		push(new V(7, 8));
		push(new V(9, 10));
		made = same(new V(1, 1));
	}
}
