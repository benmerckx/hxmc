// Deep structures promoted to the old space and collected several times in
// one process: a linked list of a million nodes, and a tree ten thousand
// levels deep whose nodes refer to their parent and hold their children in
// arrays (the shape of a UI tree). Both collectors copy depth-first with an
// explicit stack (no recursion per level), so the depth costs memory, not
// the native or wasm stack. Each structure is built, collected while live,
// checked, and dropped, three times over.
class Node {
	public var value:Int;
	public var next:Node;

	public function new(value:Int, next:Node) {
		this.value = value;
		this.next = next;
	}
}

class TreeNode {
	public var depth:Int;
	public var parent:TreeNode;
	public var children:Array<TreeNode> = [];
	public var label:String;

	public function new(depth:Int, parent:TreeNode) {
		this.depth = depth;
		this.parent = parent;
		label = "n" + depth;
		if (parent != null) parent.children.push(this);
	}
}

class DeepGc {
	static function list(n:Int):Node {
		var head:Node = null;
		for (i in 0...n)
			head = new Node(i, head);
		return head;
	}

	static function sumList(l:Node):Float {
		var s = 0.0, k = 0;
		while (l != null) {
			s += l.value;
			k++;
			l = l.next;
		}
		return s + k;
	}

	// a spine `depth` deep, each spine node with two leaves besides the next
	static function tree(depth:Int):TreeNode {
		var root = new TreeNode(0, null);
		var cur = root;
		for (d in 1...depth) {
			new TreeNode(d, cur);
			var next = new TreeNode(d, cur);
			new TreeNode(d, cur);
			cur = next;
		}
		return root;
	}

	static function checkTree(root:TreeNode):String {
		var n = 0, deepest = 0, labels = 0;
		var stack = [root];
		while (stack.length > 0) {
			var t = stack.pop();
			n++;
			if (t.depth > deepest) deepest = t.depth;
			if (t.parent != null && t.parent.children.indexOf(t) < 0) return "bad parent at " + t.depth;
			labels += t.label.length;
			for (c in t.children)
				stack.push(c);
		}
		return n + " nodes, depth " + deepest + ", labels " + labels;
	}

	static function main() {
		for (round in 0...3) {
			var l = list(1000000);
			hxmc.NativeGc.collect(true);
			hxmc.NativeGc.collect(false);
			hxmc.NativeGc.collect(true);
			Sys.println("list " + round + ": " + sumList(l));
			var t = tree(10000);
			hxmc.NativeGc.collect(true);
			hxmc.NativeGc.collect(true);
			Sys.println("tree " + round + ": " + checkTree(t) + ", list " + sumList(l));
			l = null;
			t = null;
			hxmc.NativeGc.collect(true);
		}
	}
}
