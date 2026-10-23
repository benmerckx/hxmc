package hxmc;

import haxe.ds.Vector;

// A block as the analyses below see it: a number unique in its function
// (not necessarily dense: passes drop blocks) and its edges.
typedef CfgBlock<B> = {
	var id:Int;
	var succs:Array<B>;
	var preds:Array<B>;
}

// The control-flow analyses of a function's graph, for any block type with
// numbers and edges (Mir's MBlock: MFunc.cfg, which keeps them until the
// graph changes):
//  - the reverse postorder of the blocks reached from the entry (a
//    depth-first walk taking the successors in order); the analyses number
//    the blocks by their position in it (`index`; -1: not reached, or made
//    since).
//  - the dominator tree (Cooper, Harvey and Kennedy), on first use (`dom`):
//    immediate dominators and children lists, the children in reverse
//    postorder.
//  - the loop nest, on first use (`loops`): natural loops, one per header
//    (a block that dominates a predecessor reached after it in reverse
//    postorder: a back edge), its body the blocks that reach a back edge
//    without passing the header; the innermost loop of each block, the
//    loop around each loop, depths. `irreducible`: an edge back to a block
//    that does not dominate its source (a cycle entered elsewhere than at
//    one header), which forms no loop.
// Positions, dominators and loops are by reverse postorder position.
@:generic
class Cfg<B:CfgBlock<B>> {
	public final rpo:Vector<B>;
	public final size:Int;
	var num:Vector<Int>; // by block number: the position in rpo (-1)

	// dominators (`dom`): the immediate dominator (idom[0] = 0), the first
	// child and the next sibling in the dominator tree (-1: none)
	public var idom(default, null):Null<Vector<Int>>;
	public var childHead(default, null):Null<Vector<Int>>;
	public var childNext(default, null):Null<Vector<Int>>;

	// loops (`loops`): the header of the innermost loop around a block (its
	// own for a header; -1: none), the header of the loop around a loop
	// (by header; -1: none), the number of loops around a block
	public var loopHead(default, null):Null<Vector<Int>>;
	public var loopParent(default, null):Null<Vector<Int>>;
	public var loopDepth(default, null):Null<Vector<Int>>;
	public var irreducible(default, null) = false;

	// ids: more than the blocks' numbers (a larger one is made room for)
	public function new(entry:B, ids:Int) {
		var num = new Vector<Int>(ids > entry.id ? ids : entry.id + 1);
		num.fill(-1);
		var post:Array<B> = [];
		var stack:Array<B> = [entry];
		var idx:Array<Int> = [0];
		num[entry.id] = -2;
		while (stack.length > 0) {
			var top = stack.length - 1;
			var b = stack[top];
			var k = idx[top];
			if (k < b.succs.length) {
				idx[top] = k + 1;
				var s = b.succs[k];
				if (s.id >= num.length) num = CfgTools.grow(num, s.id);
				if (num[s.id] == -1) {
					num[s.id] = -2;
					stack.push(s);
					idx.push(0);
				}
			} else {
				stack.pop();
				idx.pop();
				post.push(b);
			}
		}
		var n = post.length;
		size = n;
		rpo = new Vector<B>(n);
		for (k in 0...n) {
			var b = post[n - 1 - k];
			rpo[k] = b;
			num[b.id] = k;
		}
		this.num = num;
	}

	// the position of b in the reverse postorder (-1: not reached, or made since)
	public inline function index(b:B):Int
		return b.id < num.length ? num[b.id] : -1;

	// ---- dominators

	public function dom() {
		if (idom != null) return;
		var n = size;
		var idom = new Vector<Int>(n);
		idom.fill(-1);
		if (n > 0) idom[0] = 0;
		// the predecessors reached, by position: predIdx[predAt[k]...predAt[k + 1]]
		var predAt = new Vector<Int>(n + 1);
		var m = 0;
		for (k in 0...n) {
			predAt[k] = m;
			for (p in rpo[k].preds)
				if (index(p) >= 0) m++;
		}
		predAt[n] = m;
		var predIdx = new Vector<Int>(m);
		m = 0;
		for (b in rpo)
			for (p in b.preds) {
				var pk = index(p);
				if (pk >= 0) predIdx[m++] = pk;
			}
		var changed = true;
		while (changed) {
			changed = false;
			for (k in 1...n) {
				var d = -1;
				for (q in predAt[k]...predAt[k + 1]) {
					var p = predIdx[q];
					if (idom[p] < 0) continue;
					if (d < 0) d = p else {
						var x = p, y = d;
						while (x != y) {
							while (x > y)
								x = idom[x];
							while (y > x)
								y = idom[y];
						}
						d = x;
					}
				}
				if (d >= 0 && idom[k] != d) {
					idom[k] = d;
					changed = true;
				}
			}
		}
		var childHead = new Vector<Int>(n), childNext = new Vector<Int>(n);
		childHead.fill(-1);
		childNext.fill(-1);
		var k = n - 1;
		while (k >= 1) {
			var d = idom[k];
			childNext[k] = childHead[d];
			childHead[d] = k;
			k--;
		}
		this.idom = idom;
		this.childHead = childHead;
		this.childNext = childNext;
	}

	// whether position a dominates position x (dom first)
	public inline function dominates(a:Int, x:Int):Bool {
		var idom = this.idom;
		while (x > a)
			x = idom[x];
		return x == a;
	}

	// ---- loops

	public function loops() {
		if (loopHead != null) return;
		dom();
		var n = size;
		var head = new Vector<Int>(n), parent = new Vector<Int>(n);
		head.fill(-1);
		parent.fill(-1);
		// inner loops first (their headers come later): a loop's body walked
		// back from its back edges, an inner loop crossed from its header
		// (the outermost found so far) to the header's predecessors
		var stack:Array<Int> = [];
		var k = n;
		while (k-- > 0) {
			var isHead = false;
			for (p in rpo[k].preds) {
				var pk = index(p);
				if (pk < k) continue;
				if (!dominates(k, pk)) {
					irreducible = true;
					continue;
				}
				isHead = true;
				if (pk != k) stack.push(pk);
			}
			if (!isHead) continue;
			head[k] = k;
			while (stack.length > 0) {
				var x = stack.pop();
				// (the outermost loop found around x, else x)
				while (true) {
					var l = head[x];
					if (l < 0) break;
					if (l != x) {
						x = l;
						continue;
					}
					if (parent[x] < 0) break;
					x = parent[x];
				}
				if (x == k) continue;
				if (head[x] < 0) head[x] = k else parent[x] = k;
				for (p in rpo[x].preds) {
					var pk = index(p);
					if (pk >= 0) stack.push(pk);
				}
			}
		}
		var depth = new Vector<Int>(n);
		for (k in 0...n) {
			var h = head[k];
			depth[k] = h < 0 ? 0 : h == k ? (parent[k] < 0 ? 1 : depth[parent[k]] + 1) : depth[h];
		}
		loopHead = head;
		loopParent = parent;
		loopDepth = depth;
	}

	// whether position k is in the loop of header h (loops first)
	public inline function inLoop(k:Int, h:Int):Bool {
		var x = loopHead[k];
		while (x > h)
			x = loopParent[x];
		return x == h;
	}

	// per header, the positions of its loop's blocks in order, the header
	// first (null: not a header; loops first)
	public function loopBodies():Vector<Null<Array<Int>>> {
		var r = new Vector<Null<Array<Int>>>(size);
		for (k in 0...size) {
			var x = loopHead[k];
			while (x >= 0) {
				if (r[x] == null) r[x] = [];
				r[x].push(k);
				x = loopParent[x];
			}
		}
		return r;
	}

	// The blocks between the target and the source of an edge back in
	// reverse postorder (wider than the loops: blocks after a loop's exit
	// can come before its back edge), by position. Inline's notion of a
	// call in a loop.
	public function retreatSpans():Vector<Bool> {
		var n = size;
		var delta = new Vector<Int>(n + 1);
		for (k in 0...n)
			for (p in rpo[k].preds) {
				var pk = index(p);
				if (pk >= k) {
					delta[k]++;
					delta[pk + 1]--;
				}
			}
		var r = new Vector<Bool>(n);
		var open = 0;
		for (k in 0...n) {
			open += delta[k];
			r[k] = open > 0;
		}
		return r;
	}
}

private class CfgTools {
	// v with room for id (the new entries -1)
	public static function grow(v:Vector<Int>, id:Int):Vector<Int> {
		var n = v.length * 2;
		if (n <= id) n = id + 1;
		var w = new Vector<Int>(n);
		w.fill(-1);
		Vector.blit(v, 0, w, 0, v.length);
		return w;
	}
}
