// Struct values holding struct values (docs/plans/lowlevel.md, "Two
// representations, one core"): a copy copies what they hold, a new one holds
// zero values, on WasmGC (objects holding objects) as in linear memory.
import hxmc.scoped.*;

@:hxmc.scoped class V {
	public var x:Int;
	public var y:Int;
}

@:hxmc.scoped class Box {
	public var tag:Int;
	public var p:V;
	public var pair:Fixed<V, 2>;

	public function new(tag:Int) {
		this.tag = tag;
	}
}

@:hxmc.scoped class Code {
	// fields the constructor leaves: zero values
	public static function made():Int {
		var b = new Box(3);
		b.p.x = 4;
		b.pair[1].y = 6;
		return b.tag * 100 + b.p.x * 10 + b.pair[1].y + b.pair[0].x;
	}

	// a copy holds copies
	public static function copies():Int {
		var b = new Box(1);
		b.p.x = 2;
		b.pair[0].x = 3;
		var c = b;
		c.p.x = 7;
		c.pair[0].x = 8;
		var g = new Grow<Box>();
		g.push(b);
		g.ref(0).value.p.x = 9;
		return b.p.x * 1000 + b.pair[0].x * 100 + c.p.x * 10 + c.pair[0].x + g[0].p.x * 10000;
	}

	// a Fixed's and a Slice's elements: zero
	public static function zero():Int {
		var f = new Fixed<Box, 2>();
		f[1].p.x = 4;
		var s:Slice<Box> = Scope.slice(2);
		s[0].pair[1].x = 3;
		return f[1].p.x * 10 + s[0].pair[1].x + f[0].p.y + s[1].p.x;
	}

	// anonymous structures nested
	public static function anon():Int {
		var a = {at: {x: 1, y: 2}, n: 3};
		var b = a;
		b.at.x = 5;
		return a.at.x * 10 + b.at.x;
	}
}

class ScopedNested {
	static function main() {
		trace(Code.made());
		trace(Code.copies());
		trace(Code.zero());
		trace(Code.anon());
	}
}
