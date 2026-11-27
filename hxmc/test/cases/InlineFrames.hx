import hxmc.NativeGc;

// A small function holding a reference across a call (pair: make(a) kept
// while make(b) runs), inlined two and four times into a function with no
// frame of its own (Inline, Frames.mergeInlined): the first copy's push is
// the entry's, popped after the copy, so the copies after it must keep
// frames of their own, not slots merged into that one (once they were: the
// pop released them, and the deep calls' frames overwrote the references
// they held). Collections run during the calls (the corpus' 64 KB nursery,
// and NativeGc.collect), values held across them are checked after.
class FBox {
	public var s:String;

	public function new(s:String)
		this.s = s;
}

class InlineFrames {
	static var sink = 0;

	// (frames of their own, several deep: they reach past rt_sp)
	static function deep(s:String, n:Int):String {
		var a = s + n, b = a + "-";
		var c = n > 0 ? deep(b, n - 1) : a;
		if (n == 3 && sink % 4 == 0) NativeGc.collect(false);
		return c.length > b.length + 1000 ? a : s;
	}

	static function make(s:String):FBox {
		s = deep(s, 6);
		var junk = [];
		for (i in 0...200)
			junk.push([i, s.length, i * 3]);
		for (i in 0...3)
			sink += i * 5 + (i % 2 == 0 ? 17 : i % 7 == 0 ? 19 : 23) + (sink > 1000 ? -sink : sink >> 2) + junk.length;
		return new FBox(s + "!");
	}

	// (too large to inline)
	static function same(a:FBox, b:FBox):Int {
		for (i in 0...3)
			sink += i * 5 + (i % 2 == 0 ? 17 : i % 7 == 0 ? 19 : 23) + (sink > 1000 ? -sink : sink >> 2);
		return a.s.length == 2 && b.s.length == 2 && a.s != b.s ? 1 : 0;
	}

	static function joined(a:FBox, b:FBox):String {
		for (i in 0...3)
			sink += i * 5 + (i % 2 == 0 ? 17 : i % 7 == 0 ? 19 : 23) + (sink > 1000 ? -sink : sink >> 2);
		return a.s + b.s;
	}

	static function pair(a:String, b:String):Int
		return same(make(a), make(b));

	static function text(a:String, b:String):String
		return joined(make(a), make(b));

	static function two():Int {
		var n = pair("a", "b");
		if (sink > 100) sink = n;
		n += pair("c", "d");
		return n;
	}

	static function four():Int {
		var n = pair("a", "b");
		if (sink > 100) sink = n;
		n += pair("c", "d");
		if (sink > 200) sink = n;
		n += pair("e", "f");
		if (sink > 300) sink = n;
		n += pair("g", "h");
		return n;
	}

	// (values of the caller's held across the copies)
	static function held():String {
		var w = text("a", "b");
		if (sink > 100) sink = w.length;
		var x = text("c", "d");
		if (sink > 200) sink = x.length;
		var y = text("e", "f");
		if (sink > 300) sink = y.length;
		var z = text("g", "h");
		return [w, x, y, z].join(" ");
	}

	static function main() {
		for (round in 0...3)
			trace(two(), four(), held());
	}
}
