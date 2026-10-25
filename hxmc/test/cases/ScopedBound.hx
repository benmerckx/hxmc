import hxmc.scoped.*;

// Scope-bound classes (docs/plans/lowlevel.md, "Scope-bound classes"):
// objects of the scope that makes them, reached by reference, holding
// scoped values; a constructor or method keeps what it allocates into the
// object (Counter.new's copy of the name, push's nodes); a scoped function
// returns one to its caller (make); GC code makes them in a loop, each
// iteration's freed at its end; objects linked to each other (Node); GC
// code's methods (Tally).
@:hxmc.scoped @:hxmc.scopeBound class Node {
	public var key:Int;
	public var next:Node;

	public function new(key:Int, next:Node) {
		this.key = key;
		this.next = next;
	}
}

@:hxmc.scoped @:hxmc.scopeBound class Counter {
	public var name:Str;
	public var hits:Grow<Int>;
	public var total:Float;
	public var head:Node;

	public function new(name:Str) {
		this.name = Str.copy(name);
		hits = new Grow<Int>();
	}

	public function hit(n:Int) {
		hits.push(n);
		total += n / 2;
	}

	public function push(key:Int)
		head = new Node(key, head);

	public function sum():Int {
		var t = 0;
		for (h in hits)
			t += h;
		return t;
	}

	public function count():Int {
		var n = 0, c = head;
		while (c != null) {
			n += c.key;
			c = c.next;
		}
		return n;
	}

	public function same(o:Counter):Bool
		return o == this;
}

// GC code's methods (the class is not @:hxmc.scoped): a String copied in
@:hxmc.scopeBound class Tally {
	public var n:Int;
	public var last:Str;

	public function new() {}

	public function add(s:String) {
		n += s.length;
		last = Str.copyOf(s);
	}
}

@:hxmc.scoped class Code {
	// made here, returned: the caller's memory
	static function make(n:Int):Counter {
		var c = new Counter("made");
		for (i in 0...n)
			c.hit(i);
		return c;
	}

	static function fill(c:Counter, n:Int)
		for (i in 0...n)
			c.hits.push(i * i);

	public static function run():Int {
		var c = make(5);
		c.push(1);
		c.push(2);
		fill(c, 3);
		return c.sum() * 100 + c.count() + c.name.length * 1000;
	}
}

class ScopedBound {
	static function main() {
		var c = new Counter(Str.copyOf("gc code"));
		for (i in 1...4)
			c.hit(i);
		c.push(10);
		c.push(20);
		trace(c.name.toString(), c.sum(), c.total, c.count(), c.same(c));
		var before = Scope.used();
		var t = 0, kept = [];
		for (i in 0...1000) {
			var k = new Counter("loop");
			k.hit(i);
			k.push(i);
			// (GC objects made, some kept, while k is live: collections, minor
			// and major, see its address, outside the heap)
			var g = [for (j in 0...64) Std.string(j)];
			t += g.length - 64;
			kept.push(g);
			t += k.sum() + k.count();
		}
		trace(t, Scope.used() == before, kept[999][63]);
		trace(Code.run());
		var y = new Tally();
		y.add("abc");
		y.add("de" + Std.string(y.n));
		trace(y.n, y.last.toString());
	}
}
