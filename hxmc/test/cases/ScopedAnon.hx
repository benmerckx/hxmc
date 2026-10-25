// Anonymous structures in scoped code are struct values (docs/plans/lowlevel.md,
// "Less to write"): one value class per set of fields, the same wherever written.
import hxmc.scoped.*;

@:hxmc.scoped typedef Range = {lo:Int, hi:Int};

@:hxmc.scoped class Code {
	static var counter = 0;

	static function next():Int
		return ++counter;

	// a result of two values
	public static function minMax(s:Slice<Int>):{min:Int, max:Int} {
		var r = {min: s[0], max: s[0]};
		for (v in s) {
			if (v < r.min) r.min = v;
			if (v > r.max) r.max = v;
		}
		return r;
	}

	public static function range():Int {
		var s:Slice<Int> = Scope.slice(4);
		s[0] = 4;
		s[1] = -2;
		s[2] = 9;
		s[3] = 3;
		var m = minMax(s);
		return m.min * 100 + m.max;
	}

	// a value: a copy is another one
	public static function copies():Int {
		var p = {x: 1, y: 2};
		var q = p;
		q.x = 5;
		return p.x * 10 + q.x;
	}

	// nested, and the fields evaluated in the order written
	public static function nested():Int {
		counter = 0;
		var n = {outer: {y: next(), x: next()}, k: 3};
		return n.outer.y * 100 + n.outer.x * 10 + n.k;
	}

	// the typedef's structure and the same one written out are one type
	public static function span(r:Range):Int {
		var same:{hi:Int, lo:Int} = r;
		return same.hi - same.lo;
	}

	// elements of a Grow
	public static function pairs():Float {
		var g = new Grow<{k:Int, v:Float}>();
		for (i in 0...4)
			g.push({k: i, v: i * 0.5});
		var t = 0.0;
		for (e in g)
			t += e.k * e.v;
		return t;
	}

	// a field holding a reference: rooted at what it views
	public static function split(s:Str):{word:Str, rest:Str} {
		var i = 0;
		while (i < s.length && s[i] != " ".code)
			i++;
		var j = i < s.length ? i + 1 : i;
		return {word: s.sub(0, i), rest: s.sub(j, s.length - j)};
	}
}

class ScopedAnon {
	static function main() {
		trace(Code.range());
		trace(Code.copies());
		trace(Code.nested());
		var r:Range = {lo: 3, hi: 10};
		trace(Code.span(r));
		trace(Code.pairs());
		var w = Code.split(Str.copyOf("hello scoped world"));
		trace(w.word.toString(), w.rest.toString());
	}
}
