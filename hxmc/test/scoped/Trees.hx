import hxmc.scoped.*;

// Binary trees (the benchmarks game's): n trees of depth 16 built, walked
// and dropped, one long-lived tree of depth 14 kept throughout. Scoped:
// scope-bound objects, each tree on the data stack of its loop iteration
// (freed at its end); GC: the same class as GC objects.
//   Trees scoped|gc [n]
@:hxmc.scoped @:hxmc.scopeBound class BNode {
	public var left:BNode;
	public var right:BNode;

	public function new(left:BNode, right:BNode) {
		this.left = left;
		this.right = right;
	}
}

@:hxmc.scoped class ScopedTrees {
	static function make(d:Int):BNode
		return d == 0 ? new BNode(null, null) : new BNode(make(d - 1), make(d - 1));

	static function check(t:BNode):Int
		return t.left == null ? 1 : 1 + check(t.left) + check(t.right);

	public static function run(n:Int):Int {
		var long = make(14);
		var t = 0;
		for (i in 0...n) {
			var tree = make(16);
			t += check(tree) + (i & 1);
		}
		return t + check(long);
	}
}

class GNode {
	public var left:GNode;
	public var right:GNode;

	public function new(left:GNode, right:GNode) {
		this.left = left;
		this.right = right;
	}
}

class GcTrees {
	static function make(d:Int):GNode
		return d == 0 ? new GNode(null, null) : new GNode(make(d - 1), make(d - 1));

	static function check(t:GNode):Int
		return t.left == null ? 1 : 1 + check(t.left) + check(t.right);

	public static function run(n:Int):Int {
		var long = make(14);
		var t = 0;
		for (i in 0...n) {
			var tree = make(16);
			t += check(tree) + (i & 1);
		}
		return t + check(long);
	}
}

class Trees {
	static function main() {
		var args = Sys.args();
		var n = args.length > 1 ? Std.parseInt(args[1]) : 200;
		Sys.println(args[0] == "gc" ? GcTrees.run(n) : ScopedTrees.run(n));
	}
}
