import hxmc.scoped.*;

// Goose's bench/goose/bintrees.goose (the Benchmarks Game's binary-trees):
// many short-lived complete binary trees built, checked and dropped, one
// long-lived tree kept. Scoped: each tree's nodes in a Grow (a pool), freed
// when the function that made it returns; GC: an object per node.
//   BinaryTrees scoped|gc [maxDepth]
@:hxmc.scoped class TNode {
	public var l:Ref<TNode>;
	public var r:Ref<TNode>;

	public function new(l:Ref<TNode>, r:Ref<TNode>) {
		this.l = l;
		this.r = r;
	}
}

@:hxmc.scoped class Scoped {
	static function make(pool:Grow<TNode>, depth:Int):Ref<TNode> {
		if (depth == 0) return pool.push(new TNode(new Ref(hxmc.unsafe.Ptr.nil()), new Ref(hxmc.unsafe.Ptr.nil())));
		var l = make(pool, depth - 1);
		var r = make(pool, depth - 1);
		return pool.push(new TNode(l, r));
	}

	static function check(n:Ref<TNode>):Int {
		var l = n.value.l;
		if (l.ptr().isNull()) return 1;
		return 1 + check(l) + check(n.value.r);
	}

	static function treeCheck(depth:Int):Int {
		var pool = new Grow<TNode>();
		return check(make(pool, depth));
	}

	public static function run(maxDepth:Int, minDepth:Int, out:Grow<Int>) {
		out.push(treeCheck(maxDepth + 1));
		var long = new Grow<TNode>();
		var lroot = make(long, maxDepth);
		var d = minDepth;
		while (d <= maxDepth) {
			var iters = 1 << (maxDepth - d + minDepth);
			var sum = 0;
			for (i in 0...iters)
				sum += treeCheck(d);
			out.push(iters);
			out.push(d);
			out.push(sum);
			d += 2;
		}
		out.push(check(lroot));
	}
}

class GNode {
	public var l:GNode;
	public var r:GNode;

	public function new(l, r) {
		this.l = l;
		this.r = r;
	}
}

class Gc {
	static function make(depth:Int):GNode
		return depth == 0 ? new GNode(null, null) : new GNode(make(depth - 1), make(depth - 1));

	static function check(n:GNode):Int
		return n.l == null ? 1 : 1 + check(n.l) + check(n.r);

	public static function run(maxDepth:Int, minDepth:Int, out:Array<Int>) {
		out.push(check(make(maxDepth + 1)));
		var lroot = make(maxDepth);
		var d = minDepth;
		while (d <= maxDepth) {
			var iters = 1 << (maxDepth - d + minDepth);
			var sum = 0;
			for (i in 0...iters)
				sum += check(make(d));
			out.push(iters);
			out.push(d);
			out.push(sum);
			d += 2;
		}
		out.push(check(lroot));
	}
}

class BinaryTrees {
	static function main() {
		var args = Sys.args();
		var n = args.length > 1 ? Std.parseInt(args[1]) : 17;
		if (args[0] == "gc") {
			var out = [];
			Gc.run(n, 4, out);
			for (x in out)
				Sys.println(x);
		} else {
			var out = new Grow<Int>();
			Scoped.run(n, 4, out);
			for (x in out)
				Sys.println(x);
		}
	}
}
