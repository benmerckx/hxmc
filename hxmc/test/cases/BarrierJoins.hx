// Write barriers left out (hxmc/src/hxmc/Opt.hx, freshTargets): a reference
// stored into an object allocated since the last point that may collect,
// on every way there (joins, phis of such objects, loops), needs none; one
// stored after an arm that may collect keeps its barrier. Collections run
// between, with old objects holding the young ones stored last.
class Node {
	public var left:Node;
	public var right:Node;
	public var name:String;
	public var n:Int;

	public function new(n:Int) {
		this.n = n;
	}
}

class BarrierJoins {
	static var roots:Array<Node> = [];

	@:noinline static function churn(k:Int):Int {
		var s = 0;
		for (i in 0...k)
			s += [i].length;
		return s;
	}

	static function build(i:Int):Node {
		var a = new Node(i);
		if (i % 2 == 0) {
			a.left = new Node(i + 1);
		} else {
			a.right = new Node(i + 2);
		}
		// (both ways: nothing collected since a was made)
		a.name = "node";
		var b = i % 3 == 0 ? new Node(i * 10) : new Node(i * 100);
		b.left = new Node(-i);
		if (i % 5 == 0) churn(5000);
		// (after an arm that may collect: a may be old now)
		a.right = new Node(i + 3);
		b.right = a;
		return b;
	}

	static function main() {
		for (i in 0...200) {
			roots.push(build(i));
			if (i % 7 == 0) churn(3000);
		}
		churn(100000);
		var s = 0;
		for (r in roots)
			s += r.n + r.left.n + r.right.n + r.right.right.n + (r.right.left != null ? r.right.left.n : 0) + r.right.name.length;
		Sys.println('sum: $s');
	}
}
