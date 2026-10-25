import hxmc.scoped.*;

// The root checker accepts these (docs/plans/lowlevel.md, "The root
// checker"): a result rooted at either argument (longest), a store of one
// argument into another's memory checked at the call (put, link), memory a
// function returning references leaves to its caller (words, in a loop
// body: freed each iteration), a recursive function's summary (find), a
// pool passed down a recursion, structs and enums holding references,
// variables reassigned within their scope, GC code passing scoped values to
// GC helpers that take them.
@:hxmc.scoped class Pair {
	public var a:Str;
	public var b:Str;

	public function new(a:Str, b:Str) {
		this.a = a;
		this.b = b;
	}
}

@:hxmc.scoped class Cell {
	public var key:Int;
	public var next:Ref<Cell>;

	public function new(key:Int) {
		this.key = key;
	}
}

@:hxmc.scoped enum Value {
	Text(s:Str);
	Number(n:Int);
	Both(p:Pair);
}

@:hxmc.scoped class Code {
	static function longest(a:Str, b:Str):Str
		return a.length >= b.length ? a : b;

	static function put(g:Grow<Str>, s:Str)
		g.push(s);

	static function link(from:Ref<Cell>, to:Ref<Cell>)
		from.value.next = to;

	// a fresh Grow and what it views: the caller's
	static function words(s:Str):Grow<Str> {
		var g = new Grow<Str>();
		var start = 0;
		for (i in 0...s.length + 1)
			if (i == s.length || s[i] == " ".code) {
				if (i > start) g.push(s.sub(start, i - start));
				start = i + 1;
			}
		return g;
	}

	static function find(c:Ref<Cell>, key:Int):Ref<Cell> {
		if (c.ptr().isNull() || c.value.key == key) return c;
		return find(c.value.next, key);
	}

	static function build(pool:Grow<Cell>, n:Int):Ref<Cell> {
		var c = pool.push(new Cell(n));
		if (n > 0) link(c, build(pool, n - 1));
		return c;
	}

	static function describe(v:Value):Int
		return switch v {
			case Text(s): s.length;
			case Number(n): n;
			case Both(p): p.a.length * 10 + p.b.length;
		}

	public static function run():Int {
		var text:Str = "the quick brown fox jumps over the lazy dog";
		var best:Str = "";
		var all = new Grow<Str>();
		for (k in 0...3) {
			var ws = words(text);
			for (w in ws) {
				best = longest(best, w);
				put(all, w);
			}
		}
		var pool = new Grow<Cell>();
		var head = build(pool, 50);
		var hit = find(head, 7);
		var vs = new Grow<Value>();
		vs.push(Text(best));
		vs.push(Number(42));
		vs.push(Both(new Pair(text.sub(0, 3), best)));
		var t = 0;
		for (v in vs)
			t += describe(v);
		var p = new Pair("", "");
		p.a = best;
		p = new Pair(text, text);
		return best.length * 1000000 + all.length * 1000 + hit.value.key * 10 + (t + p.a.length) % 10;
	}
}

class ScopedRoots {
	static function count(s:Str):Int {
		var n = 0;
		for (i in 0...s.length)
			if (s[i] == "o".code) n++;
		return n;
	}

	static function main() {
		trace(Code.run());
		var s = Str.copyOf("hello world, " + Std.string(2026));
		trace(count(s));
		trace(s.toString());
	}
}
