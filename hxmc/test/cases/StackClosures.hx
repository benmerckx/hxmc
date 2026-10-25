// Escape's objects of the frame (hxmc/src/hxmc/Escape.hx, docs/plans/codegen.md,
// "Escape analysis"): closures and the boxes of the variables they capture,
// given only to functions that do not let them escape, live in their
// function's shadow-stack frame, scanned by the collector with the stack. Each
// function prints what it computes; a 64 KB nursery collects while the
// frame's objects hold young references.
class Node {
	public var v:Int;
	public var kids:Array<Node>;

	public function new(v:Int, kids:Array<Node>) {
		this.v = v;
		this.kids = kids;
	}
}

class Holder {
	public var f:Int->Int;
	public function new() {}
}

class StackClosures {
	static var kept:Int->Int;

	// calls f on every node, depth first: f does not escape
	@:noinline static function iter(n:Node, f:Node->Void) {
		f(n);
		for (k in n.kids)
			iter(k, f);
	}

	@:noinline static function times(n:Int, f:Int->Void) {
		for (i in 0...n)
			f(i);
	}

	// f escapes: stored
	@:noinline static function keep(f:Int->Int):Int {
		kept = f;
		return f(1);
	}

	@:noinline static function holder(f:Int->Int):Holder {
		var h = new Holder();
		h.f = f;
		return h;
	}

	static function tree(d:Int, v:Int):Node
		return new Node(v, d == 0 ? [] : [for (i in 0...3) tree(d - 1, v * 3 + i)]);

	// an Int box written by the closure, in the callee
	@:noinline static function sum(t:Node):Int {
		var s = 0;
		iter(t, n -> s += n.v);
		return s;
	}

	// a reference box written by the closure with young objects (the
	// barrier into an object of the frame), collections in between
	@:noinline static function collect(t:Node):String {
		var acc:Array<String> = [];
		var last:String = null;
		iter(t, n -> {
			last = "node" + n.v;
			acc.push(last);
		});
		return acc.length + " " + last + " " + acc[acc.length >> 1];
	}

	// captures references read after collections
	@:noinline static function captured(t:Node, tag:String):Int {
		var prefix = tag + "-";
		var total = 0;
		iter(t, n -> {
			var s = prefix + n.v;
			for (i in 0...20)
				s = s + ".";
			total += s.length;
		});
		return total;
	}

	// nothing live across the call: a frame for the closure alone
	@:noinline static function gather(t:Node, acc:Array<Int>)
		iter(t, n -> acc.push(n.v * 2));

	// recursion: each level's closure, the deeper ones made while it lives
	@:noinline static function depth(t:Node, d:Int, out:Array<String>) {
		iter(t, n -> if (n.v % 5 == 0 && d < 2) depth(n.kids.length > 0 ? n.kids[0] : n, d + 1, out) else if (n.v % 7 == 0) out.push(d + ":" + n.v));
	}

	// a closure made in a loop: each iteration's
	@:noinline static function loop(n:Int):Int {
		var r = 0;
		for (i in 0...n) {
			var k = i * 7;
			times(3, j -> r += k + j);
		}
		return r;
	}

	// a throw through frames holding objects, then deep calls over their memory
	@:noinline static function thrower(t:Node):Int {
		var count = 0;
		try {
			iter(t, n -> {
				count++;
				if (n.v == 20) throw "stop at " + n.v;
			});
		} catch (e:String) {
			Sys.println(e);
		}
		return count + sum(t);
	}

	// a function with a try: its closures and boxes on the frame too, read
	// by the handler after the throw
	@:noinline static function guarded(t:Node, stop:Int):String {
		var seen = 0;
		var last:Node = null;
		try {
			iter(t, n -> {
				seen++;
				last = new Node(n.v * 10, []);
				if (n.v == stop) throw n;
			});
		} catch (n:Node) {
			return "caught " + n.v + " after " + seen + " last " + last.v;
		}
		return "all " + seen + " last " + last.v;
	}

	// recursive local functions: the closure in its own box, both of the frame
	@:noinline static function deepSum(t:Node):Int {
		function loop(n:Node):Int {
			var s = n.v;
			for (k in n.kids)
				s += loop(k);
			return s;
		}
		return loop(t);
	}

	@:noinline static function mapTree(t:Node, f:Int->Int):Array<Int> {
		var out = [];
		function loop(n:Node) {
			out.push(f(n.v));
			iter(n, m -> if (m != n && m.v % 13 == 0) out.push(-m.v));
			for (k in n.kids)
				if (k.v % 2 == 0) loop(k);
		}
		loop(t);
		for (k in t.kids)
			times(2, i -> loop(k));
		return out;
	}

	// two of them calling each other, made in a loop
	@:noinline static function evenOdd(n:Int):String {
		var r = [];
		for (i in 0...n) {
			var odd:Int->Bool = null;
			function even(k:Int):Bool return k == 0 ? true : odd(k - 1);
			odd = k -> k == 0 ? false : even(k - 1);
			r.push(even(i) ? "e" : "o");
		}
		return r.join("");
	}

	static var leaked:Node->Int;

	// the function escapes: its code stores itself
	@:noinline static function leaking(t:Node):Int {
		function loop(n:Node):Int {
			leaked = loop;
			return n.kids.length == 0 ? n.v : loop(n.kids[0]);
		}
		return loop(t);
	}

	// escapes: returned
	@:noinline static function counterFn(start:Int):Void->Int {
		var c = start;
		function next():Int {
			c++;
			if (c > 100) {
				c = 0;
				return next();
			}
			return c;
		}
		return next;
	}

	// closures made in branches, one of them in a box a later closure
	// captures: each region reaches as far as what holds it is used
	@:noinline static function branches(t:Node, k:Int, derived:Bool):Int {
		final outer = k;
		return sum(t) % 7 + mapSum(k, function(n:Int):Int {
			var f:Int->Int;
			if (derived) f = x -> x % 3 == n % 3 ? x : -1 else f = x -> x < n ? x : n;
			var direct = mapSum(outer, f);
			if (direct % 5 != 0) return direct;
			var related:(Int, Int) -> Bool;
			if (derived) related = (a, b) -> (a ^ b) & 1 == 0 else related = (a, b) -> a < b;
			return mapSum(outer, x -> {
				var arr = [x, n];
				related(n, x) ? arr.length + x : -1;
			});
		});
	}

	@:noinline static function mapSum(n:Int, f:Int->Int):Int {
		var s = 0;
		for (i in 0...n)
			s += f(i);
		return s;
	}

	// escapes: the closure is kept, its box with it
	@:noinline static function escaping(k:Int):Int {
		var c = 0;
		var r = keep(x -> {
			c += x;
			x * k + c;
		});
		var h = holder(x -> x + k);
		return r + kept(2) + h.f(3);
	}

	// an inner closure capturing the outer one's box: it escapes, the box too
	@:noinline static function nested(t:Node):Int {
		var s = 0;
		var fs:Array<Void->Int> = [];
		iter(t, n -> {
			s += n.v;
			if (n.v % 10 == 0) fs.push(() -> s);
		});
		var r = 0;
		for (f in fs)
			r += f();
		return r;
	}

	static function main() {
		var t = tree(4, 1);
		Sys.println(sum(t));
		Sys.println(collect(t));
		Sys.println(captured(t, "tag"));
		Sys.println(loop(100));
		Sys.println(thrower(t));
		Sys.println(escaping(5));
		Sys.println(nested(t));
		Sys.println(guarded(t, 30));
		Sys.println(guarded(t, -1));
		Sys.println(deepSum(t));
		var b = 0;
		for (i in 0...300)
			b += branches(t, i % 37, i % 2 == 0);
		Sys.println(b);
		Sys.println(mapTree(t, x -> x * 3).join(","));
		Sys.println(evenOdd(20));
		Sys.println(leaking(t) + " " + leaked(t.kids[1]));
		var c = counterFn(98);
		Sys.println(c() + " " + c() + " " + c());
		var acc = [];
		gather(t, acc);
		Sys.println(acc.length + " " + acc[7]);
		var out = [];
		depth(t, 0, out);
		Sys.println(out.length + " " + out[3] + " " + out[out.length - 1]);
		var total = 0;
		for (i in 0...200)
			total += sum(t) + captured(t, "x" + i) % 7;
		Sys.println(total);
	}
}
