import hxmc.NativeGc;

// @:hxmc.compact enums (docs/hxmc.md, "Compressed references"): their
// constructors' arguments are packed as a compact class's fields, an Int, a
// Bool or a reference (not a type parameter's value, a Null<Int>, a Float) in
// 4 bytes, natively on Linux and Windows on x86-64; elsewhere a slot each, as
// without the annotation. Values built and matched through minor and major
// collections (the corpus' small nurseries, RT_VERIFY), every kind of
// argument, reflection (Type.enumParameters, enumEq, createEnum, Std.string,
// haxe.Serializer, EnumValueMap's keys), a value the escape analysis
// replaces, generic constructors, and threads building and collecting at once.
@:hxmc.compact
enum Tree {
	Leaf(v:Int);
	Node(l:Tree, r:Tree, tag:String);
	Pair(t:Tree, n:Int);
	Mixed(a:Int, s:String, f:Float, b:Bool, n:Null<Int>, t:Tree, arr:Array<Int>);
	Empty;
}

@:hxmc.compact
enum Chain<T> {
	Link(v:T, next:Chain<T>);
	End;
}

// an enum without the annotation, as an argument of a compact one
enum Plain {
	P(s:String);
}

@:hxmc.compact
enum Holder {
	Hold(p:Plain, fn:Int->Int, any:Dynamic, anon:{x:Int}, o:Holder);
}

class CompactEnums {
	// an object's slots (its header: hxmc.rt.Types)
	@:hxmc.unsafe static function slots(o:Dynamic):Int
		return hxmc.unsafe.Mem.getU16(hxmc.unsafe.Mem.addr(o), -6);

	static function build(depth:Int, salt:Int):Tree {
		if (depth == 0) return Leaf(salt);
		var l = build(depth - 1, salt * 2 + 1), r = build(depth - 1, salt * 2 + 2);
		return switch depth % 3 {
			case 0: Node(l, r, "n" + salt);
			case 1: Pair(Node(l, r, null), salt);
			case _: Mixed(salt, "m" + salt, salt / 2, salt & 1 == 0, salt % 5 == 0 ? null : salt, Node(l, r, "x"), [salt, depth]);
		}
	}

	static function sum(t:Tree):Int
		return switch t {
			case Leaf(v): v;
			case Node(l, r, tag): sum(l) + sum(r) + (tag == null ? 0 : tag.length);
			case Pair(t, n): sum(t) + n;
			case Mixed(a, s, f, b, n, t, arr): a + s.length + Std.int(f * 2) + (b ? 1 : 0) + (n == null ? 7 : n) + sum(t) + arr[0] + arr[1];
			case Empty: 0;
		}

	// structural equality, arrays by their elements
	static function same(a:Tree, b:Tree):Bool
		return switch [a, b] {
			case [Leaf(x), Leaf(y)]: x == y;
			case [Node(l, r, s), Node(l2, r2, s2)]: same(l, l2) && same(r, r2) && s == s2;
			case [Pair(t, n), Pair(t2, n2)]: same(t, t2) && n == n2;
			case [Mixed(a, s, f, b, n, t, arr), Mixed(a2, s2, f2, b2, n2, t2, arr2)]:
				a == a2 && s == s2 && f == f2 && b == b2 && n == n2 && same(t, t2) && arr.join(",") == arr2.join(",");
			case [Empty, Empty]: true;
			case _: false;
		}

	// a value that never leaves the function (the escape analysis)
	static function local(a:Int, b:Int):Int {
		var p = Pair(Leaf(a), b);
		return switch p {
			case Pair(Leaf(x), n): x * 10 + n;
			case _: -1;
		}
	}

	static function chain(n:Int):Int {
		var ci = End, cs = End;
		for (k in 0...n) {
			ci = Link(k, ci);
			cs = Link("s" + k, cs);
		}
		NativeGc.collect(false);
		var si = 0, ss = 0;
		while (true)
			switch ci {
				case Link(v, next):
					si += v;
					ci = next;
				case End: break;
			}
		while (true)
			switch cs {
				case Link(v, next):
					ss += v.length;
					cs = next;
				case End: break;
			}
		return si + ss;
	}

	static function main() {
		// (Leaf: none where there are compressed references, Linux and Windows
		// on x86-64, hxmc.Main.compactRefs (its Int in the header: HeaderEnums);
		// Node 2, Pair 1, Mixed 5, Link 2, Hold 3: else a slot per argument)
		var compressed = hxmc.unsafe.Mem.os() == 0 || hxmc.unsafe.Mem.os() == 2 && !hxmc.unsafe.Mem.arm() || hxmc.unsafe.Mem.os() == 1 && hxmc.unsafe.Mem.platform() == 0;
		var sizes = [
			slots(Leaf(1)),
			slots(Node(null, null, "a")),
			slots(Pair(null, 1)),
			slots(Mixed(1, "", 1.5, true, null, null, null)),
			slots(Link(1, End)),
			slots(Hold(null, null, null, null, null))
		];
		trace(sizes.join(",") == (compressed ? "0,2,1,5,2,3" : "1,3,2,7,2,5") ? "sizes ok" : "sizes " + sizes);
		trace(local(3, 4));

		var t = build(12, 1);
		var expect = sum(t);
		// (garbage between: many minor collections)
		var junk = 0;
		for (k in 0...100000)
			junk += sum(build(1, k)) & 1;
		trace(sum(t) == expect, junk > 0);
		NativeGc.collect(false);
		trace(sum(t) == expect);
		NativeGc.collect(true);
		trace(sum(t) == expect);
		trace(chain(5000));

		// every argument kind, read back after collections
		var m = Mixed(-3, "str" + 1, 2.25, true, 99, Leaf(5), [1, 2]);
		var m2 = Mixed(-3, "str1", 2.25, false, null, Pair(Leaf(6), 7), [3]);
		NativeGc.collect(true);
		switch [m, m2] {
			case [Mixed(a, s, f, b, n, Leaf(v), arr), Mixed(a2, s2, f2, b2, n2, Pair(Leaf(w), k), arr2)]:
				trace(a, s, f, b, n, v, arr, a2, s2, f2, b2, n2, w, k, arr2);
			case _:
				trace("no match");
		}
		var h = Hold(P("plain"), x -> x + 1, "dyn", {x: 4}, Hold(P("in"), x -> x * 2, 3, {x: 5}, null));
		NativeGc.collect(false);
		switch h {
			case Hold(P(s), fn, any, anon, Hold(P(s2), fn2, any2, anon2, o)):
				trace(s, fn(1), any, anon.x, s2, fn2(4), any2, anon2.x, o);
			case _:
		}

		// reflection
		trace(Type.enumParameters(m));
		trace(Type.enumParameters(Node(Leaf(1), Empty, "t")));
		trace(Type.enumIndex(m), Type.enumConstructor(m), Type.enumIndex(Empty));
		trace(Std.string(m), Std.string(Pair(Leaf(2), 3)), "" + Link("a", Link("b", End)));
		// (arrays compare by identity: Mixed's arr)
		var e1 = Node(Leaf(1), Pair(Leaf(2), 3), "x"), e2 = Node(Leaf(1), Pair(Leaf(2), 3), "x" + "");
		trace(Type.enumEq(e1, e2), Type.enumEq(e1, Node(Leaf(1), Pair(Leaf(2), 4), "x")), Type.enumEq(build(4, 9), build(4, 9)), Type.enumEq(m, m2), same(build(6, 9), build(6, 9)), same(build(6, 9), build(6, 8)));
		var c = Type.createEnum(Tree, "Node", [Leaf(1), Leaf(2), "made" + 1]);
		var c2 = Type.createEnumIndex(Tree, 3, [7, "s", 0.5, true, null, c, [8]]);
		NativeGc.collect(false);
		trace(sum(c), sum(c2), Std.string(c2));
		var s = haxe.Serializer.run(build(3, 2));
		var u:Tree = haxe.Unserializer.run(s);
		trace(s, same(u, build(3, 2)), sum(u) == sum(build(3, 2)));
		var map = new Map<Tree, Int>();
		for (k in 0...50)
			map.set(Pair(Leaf(k), k % 5), k);
		NativeGc.collect(true);
		var found = 0;
		for (k in 0...50)
			if (map.get(Pair(Leaf(k), k % 5)) == k) found++;
		trace(found, map.get(Pair(Leaf(1), 2)));
		var dyn:Dynamic = m;
		trace(Reflect.isEnumValue(dyn), Type.getEnum(dyn) == Tree);

		// threads building, collecting and checking at once (one after another on wasm32-wasi)
		var results = [for (_ in 0...4) false];
		function work(k:Int) {
			var t = build(11, 10 + k);
			var e = sum(t);
			for (j in 0...50000)
				sum(build(1, j));
			NativeGc.collect(k % 2 == 0);
			results[k] = sum(t) == e && same(t, build(11, 10 + k));
		}
		#if (hxmc.target != "wasm32-wasi")
		var lock = new sys.thread.Lock();
		for (k in 0...4)
			sys.thread.Thread.create(() -> {
				work(k);
				lock.release();
			});
		for (_ in 0...4)
			lock.wait();
		#else
		for (k in 0...4)
			work(k);
		#end
		trace(results);
		trace(sum(t) == expect);
	}
}
