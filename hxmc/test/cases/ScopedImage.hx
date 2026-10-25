// Images (docs/plans/lowlevel.md, "Serialization: relative references"): a
// Grow's elements as bytes, the same on every target, and back after a
// check; Rels are indexes, so the bytes mean the same wherever they are.
import hxmc.scoped.*;
import hxmc.unsafe.UInt8;

@:hxmc.scoped class V {
	public var x:Int;
	public var y:Int;
}

@:hxmc.scoped class Node {
	public var val:Int;
	public var weight:Float;
	public var on:Bool;
	public var tag:UInt8;
	public var next:Rel<Node>;
	public var kids:Fixed<Rel<Node>, 2>;
	public var at:V;
	public var big:hxmc.I64;

	public function new() {}
}

@:hxmc.scoped class Code {
	static function build(g:Grow<Node>) {
		for (i in 0...5) {
			var n = new Node();
			n.val = i * 10;
			n.weight = i + 0.25;
			n.on = i % 2 == 0;
			n.tag = 200 + i;
			n.next = i < 4 ? Rel.at(i + 1) : Rel.none();
			// (values with effects in locals first: a Fixed field's element set)
			var first:Rel<Node> = Rel.at(0), prev:Rel<Node> = i > 0 ? Rel.at(i - 1) : Rel.none();
			n.kids[0] = first;
			n.kids[1] = prev;
			n.at.x = i;
			n.at.y = -i;
			n.big = (i : hxmc.I64) << 40;
			g.push(n);
		}
	}

	// the list walked through its Rels
	static function walk(g:Grow<Node>):Float {
		var t = 0.0, r:Rel<Node> = Rel.at(0);
		while (!r.isNone()) {
			var n = r.get(g);
			t += n.value.val + n.value.weight + (n.value.on ? 1000 : 0) + n.value.tag + n.value.at.x * 3 + n.value.at.y;
			t += (n.value.big >> 40).toInt() * 7 + n.value.kids[0].index() + n.value.kids[1].index();
			r = n.value.next;
		}
		return t;
	}

	public static function image():Str {
		var g = new Grow<Node>();
		build(g);
		var b = Image.of(g);
		var sum = 0;
		for (i in 0...b.length)
			sum = (sum * 31 + b[i]) & 0xFFFFFF;
		var h = new Grow<Node>();
		var ok = Image.load(b, h);
		return '${b.length} $sum $ok ${h.length} ${walk(g)} ${walk(h)}';
	}

	// each byte made 255 in turn: the images that no longer load
	public static function hostile():Str {
		var g = new Grow<Node>();
		build(g);
		var b = Image.of(g);
		var bad = 0;
		for (k in 0...b.length) {
			var c:Slice<UInt8> = Scope.slice(b.length);
			for (i in 0...b.length)
				c[i] = b[i];
			c[k] = 255;
			var h = new Grow<Node>();
			if (!Image.load(c, h)) bad++;
		}
		var short = new Grow<Node>();
		var into = new Grow<Node>();
		into.push(new Node());
		return '$bad ${Image.load(b.sub(0, b.length - 1), short)} ${Image.load(b, into)}';
	}
}

class ScopedImage {
	static function main() {
		trace(Code.image().toString());
		trace(Code.hostile().toString());
	}
}
