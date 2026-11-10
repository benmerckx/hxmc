import hxmc.NativeGc;

// @:hxmc.compact classes (docs/hxmc.md, "Compressed references"): their own
// reference fields are 4 bytes in the object (natively on Linux and Windows on
// x86-64; elsewhere the annotation changes nothing), read and written as whole references.
// Structures of them promoted, collected minor and major (with a 64 KB
// nursery: many minor collections), old objects made to refer to young ones
// (the write barrier remembers the object), every kind of reference field
// (objects, strings literal and built, arrays, enum values, closures, Dynamic,
// anonymous structures), fields that stay 8 bytes (a type parameter's value,
// a Null<Int>, a non-compact superclass's), Dynamic access and reflection,
// structural access through a typedef, an object the escape analysis replaces,
// and threads building and collecting at once.
enum Color {
	Red;
	Rgb(r:Int, g:Int, b:Int);
}

class Plain {
	public var tag:String;

	public function new(tag:String)
		this.tag = tag;
}

@:hxmc.compact
class Node {
	public var id:Int;
	public var next:Node;
	public var name:String;
	public var flag:Bool;
	public var kids:Array<Node>;
	public var color:Color;
	public var any:Dynamic;
	public var fn:Int->Int;
	public var maybe:Null<Int>;
	public var plain:Plain;
	public var anon:{x:Int};

	public function new(id:Int, next:Node) {
		this.id = id;
		this.next = next;
	}
}

// (compact as its superclass is)
class Leaf extends Node {
	public var extra:Node;
	public var count:Int;

	public function new(id:Int, next:Node, extra:Node) {
		super(id, next);
		this.extra = extra;
		count = id * 2;
	}
}

@:hxmc.compact
class Gen<T> {
	public var v:T;
	public var other:Gen<T>;

	public function new(v:T, other:Gen<T>) {
		this.v = v;
		this.other = other;
	}
}

class Base {
	public var p:Plain;
	public var x:Int;

	public function new() {}
}

@:hxmc.compact
class Derived extends Base {
	public var q:Plain;
	public var r:Derived;

	public function new(r:Derived) {
		super();
		this.r = r;
		p = new Plain("p");
		q = new Plain("q");
	}
}

typedef Named = {
	var name:String;
	var id:Int;
}

class CompactRefs {
	static var sink:Array<Dynamic> = [];

	static function build(n:Int, salt:Int):Node {
		var head:Node = null;
		var k = 7;
		for (i in 0...n) {
			var node = i % 5 == 0 ? new Leaf(i, head, head == null ? null : head.next) : new Node(i, head);
			node.name = i % 3 == 0 ? "static" : "n" + (i + salt);
			node.flag = i & 1 == 0;
			node.color = i % 4 == 0 ? Red : Rgb(i & 255, salt, 3);
			if (i % 100 == 0) node.kids = [head, node];
			node.any = i % 2 == 0 ? (i : Dynamic) : ("s" + i : Dynamic);
			var c = i + salt;
			node.fn = i % 2 == 0 ? x -> x + 1 : x -> x + c;
			node.maybe = i % 7 == 0 ? null : i;
			node.anon = {x: i};
			head = node;
		}
		return head;
	}

	static function check(head:Node, n:Int, salt:Int):String {
		var bad = 0, i = n, sum = 0.0;
		var l = head;
		while (l != null) {
			i--;
			if (l.id != i) bad++;
			if (l.name != (i % 3 == 0 ? "static" : "n" + (i + salt))) bad++;
			if (l.flag != (i & 1 == 0)) bad++;
			switch l.color {
				case Red:
					if (i % 4 != 0) bad++;
				case Rgb(r, g, b):
					if (r != i & 255 || g != salt || b != 3) bad++;
			}
			if (i % 100 == 0 && (l.kids.length != 2 || l.kids[1] != l || l.kids[0] != l.next)) bad++;
			if (i % 2 == 0 ? l.any != i : l.any != "s" + i) bad++;
			if (l.fn(10) != (i % 2 == 0 ? 11 : 10 + i + salt)) bad++;
			if (l.maybe != (i % 7 == 0 ? null : i)) bad++;
			if (l.anon.x != i) bad++;
			if (Std.isOfType(l, Leaf)) {
				var f:Leaf = cast l;
				if (f.count != i * 2) bad++;
				if (f.extra != (f.next == null ? null : f.next.next)) bad++;
			}
			if (l.plain != null && l.plain.tag != "y" + i) bad++;
			sum += l.id;
			l = l.next;
		}
		if (i != 0) bad++;
		return 'n=$n sum=$sum bad=$bad';
	}

	// old objects made to refer to young ones, then many minor collections
	static function barrier(head:Node):Int {
		var l = head;
		while (l != null) {
			if (l.id % 10 == 0) l.plain = new Plain("y" + l.id);
			l = l.next;
		}
		// (garbage: minor collections, the old objects' new fields their only references)
		var junk = 0;
		for (k in 0...200000)
			junk += new Plain("j" + k).tag.length;
		return junk;
	}

	// a compact object that never leaves the function (the escape analysis)
	static function local(a:Int, b:Int):Int {
		var x = new Node(a, null);
		var y = new Node(b, x);
		y.name = "loc";
		return y.next.id + y.id + y.name.length;
	}

	// an object's slots (its header: hxmc.rt.Types)
	@:hxmc.unsafe static function slots(o:Dynamic):Int
		return hxmc.unsafe.Mem.getU16(hxmc.unsafe.Mem.addr(o), -6);

	static function main() {
		// (Node: 6 slots, its references compressed but `maybe`, where there
		// are compressed references, Linux, Windows on x86-64 and macOS (hxmc.Main.compactRefs);
		// elsewhere 10, the annotation changing nothing)
		var compressed = hxmc.unsafe.Mem.os() == 0 || hxmc.unsafe.Mem.os() == 2 && !hxmc.unsafe.Mem.arm() || hxmc.unsafe.Mem.os() == 1 && hxmc.unsafe.Mem.platform() == 0;
		var sizes = [slots(new Node(1, null)), slots(new Leaf(1, null, null)), slots(new Gen(1, null)), slots(new Derived(null))];
		trace(sizes.join(",") == (compressed ? "6,7,2,3" : "10,12,2,4") ? "sizes ok" : "sizes " + sizes);
		trace(local(3, 4));
		var head = build(30000, 1);
		trace(check(head, 30000, 1));
		NativeGc.collect(false);
		trace(check(head, 30000, 1));
		NativeGc.collect(true);
		trace(check(head, 30000, 1));
		trace(barrier(head) > 0);
		trace(check(head, 30000, 1));
		NativeGc.collect(true);
		NativeGc.collect(true);
		trace(check(head, 30000, 1));

		// type parameters: their values stay words (an Int encoded, or a reference)
		var gi = new Gen(1, null);
		for (k in 2...1000)
			gi = new Gen(k, gi);
		var gs = new Gen("a", null);
		for (k in 0...1000)
			gs = new Gen("b" + k, gs);
		NativeGc.collect(true);
		var si = 0, ss = 0;
		while (gi != null) {
			si += gi.v;
			gi = gi.other;
		}
		while (gs != null) {
			ss += gs.v.length;
			gs = gs.other;
		}
		trace(si, ss);

		// a non-compact superclass's fields stay 8 bytes
		var d:Derived = null;
		for (k in 0...1000) {
			d = new Derived(d);
			d.x = k;
		}
		NativeGc.collect(false);
		var dn = 0;
		var dd = d;
		while (dd != null) {
			if (dd.p.tag == "p" && dd.q.tag == "q") dn += dd.x;
			dd = dd.r;
		}
		trace(dn);

		// Dynamic access and reflection
		var n = new Node(42, head);
		n.name = "dyn" + 1;
		var dyn:Dynamic = n;
		trace(dyn.name, dyn.next.id, dyn.id);
		dyn.name = "set" + 2;
		dyn.next = head.next;
		trace(n.name, n.next.id);
		trace(Reflect.field(n, "name"), Reflect.field(n, "color"));
		Reflect.setField(n, "plain", new Plain("refl"));
		NativeGc.collect(false);
		trace(n.plain.tag, (Reflect.field(n, "plain") : Plain).tag);
		var fields = Type.getInstanceFields(Node);
		fields.sort(Reflect.compare);
		trace(fields.join(","));
		var named:Named = n;
		trace(named.name, named.id);
		named.name = "struct" + 3;
		trace(n.name);
		// an old object's field set by Dynamic access to a young object
		NativeGc.collect(true);
		dyn.plain = new Plain("young" + 4);
		for (k in 0...100000)
			sink[k & 15] = new Plain("j" + k);
		trace(n.plain.tag);

		#if (hxmc.target != "wasm32-wasi")
		// threads building, collecting and checking at once
		var lock = new sys.thread.Lock();
		var results = [for (_ in 0...4) ""];
		for (t in 0...4)
			sys.thread.Thread.create(() -> {
				var h = build(20000, 10 + t);
				barrier(h);
				NativeGc.collect(t % 2 == 0);
				results[t] = check(h, 20000, 10 + t);
				lock.release();
			});
		for (_ in 0...4)
			lock.wait();
		for (r in results)
			trace(r);
		#end
		trace(check(head, 30000, 1));

		var rs = new RecSub();
		rs.next = new RecSub();
		rs.next.back = rs;
		rs.name = "rec";
		NativeGc.collect(true);
		trace(rs.next.back == rs && rs.name == "rec" && Reflect.field(rs.next, "back") == rs);
	}
}

// a compact class whose field types name its subclass (the subclass's
// layout is made while the superclass's fields are still untyped: Lower's
// checks wait for them)
@:hxmc.compact
class RecBase {
	public var next:RecSub;
	public var name:String;

	public function new() {}
}

class RecSub extends RecBase {
	public var back:RecBase;

	public function new() {
		super();
	}
}
