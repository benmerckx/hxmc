import hxmc.scoped.*;

// Scoped memory (docs/plans/lowlevel.md, "Scoped memory"): scoped classes
// (struct values with Str and Ref fields), scoped enums (value enums:
// construction, switch, payloads of struct values, equality), Grow (push
// returns references that survive growth), Slice, Str, Pool; scopes that
// reset (function bodies, loops, blocks; a function returning references
// leaves its memory to its caller), a tree built in a pool by a recursive
// function; GC code calling scoped code, holding scoped values in its locals
// across allocations, copying out, and an exception thrown through a scope
// (the catch resets). The data stacks' use is printed where it must be back
// to where it was.
@:hxmc.scoped class Item {
	public var key:Int;
	public var val:Float;
	public var name:Str;

	public function new(key:Int, val:Float, name:Str) {
		this.key = key;
		this.val = val;
		this.name = name;
	}
}

@:hxmc.scoped class Node {
	public var key:Int;
	public var left:Ref<Node>;
	public var right:Ref<Node>;
	public var leaf:Bool;

	public function new(key:Int) {
		this.key = key;
		leaf = true;
	}
}

@:hxmc.scoped enum Shape {
	Circle(r:Float);
	Rect(w:Float, h:Float);
	Label(text:Str, size:Int);
	Dot;
}

@:hxmc.scoped enum Token {
	Num(v:Int);
	Op(c:Int);
	End;
}

@:hxmc.scoped class Code {
	static function area(s:Shape):Float
		return switch s {
			case Circle(r): 3 * r * r;
			case Rect(w, h): w * h;
			case Label(t, size): t.length * size;
			case Dot: 0;
		}

	public static function shapes():Float {
		var g = new Grow<Shape>();
		g.push(Circle(1));
		g.push(Rect(2, 3.5));
		g.push(Label("four", 10));
		g.push(Dot);
		var t = 0.0;
		for (s in g)
			t += area(s);
		var a = Rect(1, 2), b = Rect(1, 2), c = Rect(2, 1);
		if (a == b) t += 1000;
		if (a == c) t += 2000;
		var d = a;
		d = Dot;
		return t + area(a) + area(d);
	}

	// references into a Grow stay valid as it grows
	public static function stable(n:Int):Int {
		var items = new Grow<Item>();
		var marks = new Grow<Ref<Item>>();
		for (i in 0...n) {
			var e = items.push(new Item(i, i * 0.5, "x"));
			if (i % 1000 == 0) marks.push(e);
		}
		for (m in marks)
			m.value.key += 1;
		var t = 0;
		for (i in 0...items.length)
			t += items[i].key;
		return t - (n * (n - 1) >> 1);
	}

	static function tokens(s:Str, out:Grow<Token>) {
		var i = 0;
		while (i < s.length) {
			var c = s[i];
			if (c >= "0".code && c <= "9".code) {
				var v = 0;
				while (i < s.length && s[i] >= "0".code && s[i] <= "9".code)
					v = v * 10 + s[i++] - "0".code;
				out.push(Num(v));
				continue;
			}
			if (c != " ".code) out.push(Op(c));
			i++;
		}
		out.push(End);
	}

	public static function calc(text:Str):Int {
		var ts = new Grow<Token>();
		tokens(text, ts);
		var acc = 0, op = "+".code;
		for (t in ts)
			switch t {
				case Num(v): acc = op == "+".code ? acc + v : op == "-".code ? acc - v : acc * v;
				case Op(c): op = c;
				case End:
			}
		return acc;
	}

	// a result holding references: the Grow and its slice are the caller's
	static function range(n:Int):Slice<Int> {
		var g = new Grow<Int>();
		for (i in 0...n)
			g.push(i * i);
		return g.slice();
	}

	static function firstWord(s:Str):Str {
		var i = s.indexOf(" ".code);
		return s.sub(0, i < 0 ? s.length : i);
	}

	public static function views():Int {
		var r = range(10);
		var t = 0;
		for (x in r)
			t += x;
		var w = firstWord("hello scoped world");
		var c = Str.copy(w);
		var h:Str = "hello";
		return t * 1000 + w.length * 100 + (c.eq(w) ? 10 : 0) + (c.eq(h) ? 1 : 0);
	}

	// a tree in a pool (a Grow of nodes) by a recursive function
	static function insert(pool:Grow<Node>, root:Ref<Node>, key:Int) {
		var cur = root;
		while (true) {
			var n = cur.value;
			if (key == n.key) return;
			if (key < n.key) {
				if (n.leaf || n.left.isNull()) {
					cur.value.left = pool.push(new Node(key));
					cur.value.leaf = false;
					return;
				}
				cur = n.left;
			} else {
				if (n.right.isNull()) {
					cur.value.right = pool.push(new Node(key));
					cur.value.leaf = false;
					return;
				}
				cur = n.right;
			}
		}
	}

	static function depth(n:Ref<Node>):Int {
		if (n.isNull()) return 0;
		var l = depth(n.value.left), r = depth(n.value.right);
		return 1 + (l > r ? l : r);
	}

	static function count(n:Ref<Node>):Int
		return n.isNull() ? 0 : 1 + count(n.value.left) + count(n.value.right);

	public static function tree(n:Int):Int {
		var pool = new Grow<Node>();
		var root = pool.push(new Node(n >> 1));
		var x = 12345;
		for (i in 0...n) {
			x = (x * 1103515245 + 12345) & 0x7fffffff;
			insert(pool, root, x % (n * 4));
		}
		return count(root) * 1000 + (depth(root) < 64 ? 1 : 0);
	}

	// scopes: what a loop body allocates is freed at its end
	public static function loops(k:Int):Int {
		var t = 0;
		for (i in 0...k) {
			var s = Scope.slice(64);
			s[63] = i;
			t += s[63] & 1;
		}
		for (i in 0...k) {
			var g = new Grow<Int>();
			g.push(i);
			if (i % 2 == 0) continue;
			t += g.length;
		}
		return t;
	}

	// a pool passed in: what it makes is the caller's
	static function label(pool:Pool, i:Int):Str {
		var b = new Grow<Int>();
		var s = pool.str(i % 2 == 0 ? "even" : "odd");
		return s;
	}

	public static function pooled():Int {
		var pool = new Pool();
		var names = new Grow<Str>();
		for (i in 0...100)
			names.push(label(pool, i));
		var t = 0;
		for (s in names)
			t += s.length;
		return t;
	}

	public static function sumItems(items:Slice<Item>):Float {
		var t = 0.0;
		for (it in items)
			t += it.val + it.name.length;
		return t;
	}

	public static function makeItems(n:Int):Slice<Item> {
		var g = new Grow<Item>();
		for (i in 0...n)
			g.push(new Item(i, i * 1.5, "item"));
		return g.slice();
	}
}

class Fail {
	public function new() {}
}

class ScopedValues {
	static function main() {
		trace(Code.shapes());
		trace(Code.stable(100000));
		trace(Code.calc("12 + 30 * 2 - 4"));
		trace(Code.views());
		trace(Code.tree(20000));
		trace(Code.loops(1000000));
		trace(Code.pooled());
		var before = Scope.used();
		// GC code: scoped values in locals, across allocations, copied out
		var items = Code.makeItems(1000);
		var keep = [];
		for (i in 0...100)
			keep.push("gc " + i);
		trace(Code.sumItems(items));
		var s = Str.copyOf("from " + keep[42]);
		trace(s.toString() + " " + s.length);
		// a GC loop calling scoped code allocates nothing that stays
		var t = 0;
		for (i in 0...100000) {
			var w = Str.copyOf(keep[i % 100]);
			t += w.length;
		}
		trace(t);
		// an exception through scopes: the catch resets
		for (i in 0...3)
			try {
				var big = Code.makeItems(10000);
				if (big.length > 0) throw new Fail();
			} catch (e:Fail) {}
		trace(Scope.used() - before > 100000 ? "kept" : "freed");
		// (natively the Grow main holds, items, keeps its stack; WasmGC claims none)
		trace(Scope.claimed() <= 1 ? "claims bounded" : "claims: " + Scope.claimed());
	}
}
