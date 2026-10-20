// Escape analysis (hxmc/src/hxmc/Escape.hx): closures made and called in
// the same function (their calls go to their function, inlined, then the
// closure and the boxes of the variables it captures are replaced; captured
// references stay where the collector sees them), and the closures that
// escape. Each function prints what it computes, the same either way; the
// collections a 64 KB nursery makes check the references kept.
class Item {
	public var name:String;
	public var weight:Int;

	public function new(name:String, weight:Int) {
		this.name = name;
		this.weight = weight;
	}
}

class Writer {
	public var out:Array<String> = [];
	public var total = 0;

	public function new() {}

	public inline function each<T>(l:Array<T>, f:T->Void) {
		for (x in l)
			f(x);
	}

	function add(i:Item) {
		out.push(i.name);
		total += i.weight;
	}

	// a bound method called in place: the closure captures this
	@:noinline public function writeAll(l:Array<Item>) {
		each(l, add);
	}
}

class EscapeClosures {
	static var kept:Void->Int;

	static inline function apply(n:Int, f:Int->Int):Int {
		var s = 0;
		for (i in 0...n)
			s += f(i);
		return s;
	}

	// captures an Int
	@:noinline static function capInt(n:Int, k:Int):Int
		return apply(n, i -> i * k);

	// captures a reference, across allocations and calls
	@:noinline static function capRef(n:Int, tag:String):Int
		return apply(n, i -> (tag + i).length);

	// mutates a captured variable (a box)
	@:noinline static function counter(n:Int):Int {
		var count = 0;
		var bump = (d:Int) -> count += d;
		for (i in 0...n)
			bump(i & 3);
		return count;
	}

	// a captured reference variable reassigned in the closure
	@:noinline static function lastName(items:Array<Item>):String {
		var best:Item = null;
		var pick = (i:Item) -> if (best == null || i.weight > best.weight) best = i;
		for (i in items)
			pick(i);
		return best == null ? "none" : best.name + ":" + best.weight;
	}

	// kept: stored
	@:noinline static function stored(k:Int):Int {
		var f = () -> k * 2;
		kept = f;
		return f();
	}

	// kept: returned
	@:noinline static function returned(k:Int):Int->Int
		return x -> x + k;

	// kept: given to a function not inlined
	@:noinline static function given(l:Array<Int>, k:Int):Array<Int>
		return l.map(x -> x * k);

	// two closures of one function meet at a phi
	@:noinline static function either(c:Bool, k:Int):Int {
		var f = c ? (x:Int) -> x + k : (x:Int) -> x - k;
		return f(10);
	}

	static function main() {
		Sys.println(capInt(100, 3));
		Sys.println(capRef(3000, "item-"));
		Sys.println(counter(1000));
		var items = [for (i in 0...500) new Item("n" + i, (i * 37) % 101)];
		Sys.println(lastName(items) + " " + lastName([]));
		var w = new Writer();
		for (r in 0...20)
			w.writeAll(items);
		Sys.println(w.out.length + " " + w.total + " " + w.out[w.out.length - 1]);
		Sys.println(stored(21) + " " + kept());
		Sys.println(returned(5)(6));
		Sys.println(given([1, 2, 3], 4).join(","));
		Sys.println(either(true, 3) + " " + either(false, 3));
	}
}
