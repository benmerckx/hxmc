// Scoped classes of scalars in a Grow, a Slice, a Fixed: on WasmGC a struct
// of arrays (docs/plans/lowlevel.md, "Two representations, one core"), here
// the same values on every target.
import hxmc.scoped.*;

@:hxmc.scoped class P {
	public var x:Float;
	public var n:Int;
	public var on:Bool;
}

@:hxmc.scoped class Holder {
	public var tag:Int;
	public var two:Fixed<P, 2>;

	public function new(tag:Int)
		this.tag = tag;
}

@:hxmc.scoped class Code {
	// fields in place: set, compound, increments; growth past the first array
	public static function fields():Float {
		var g = new Grow<P>();
		for (i in 0...20)
			g.push({x: i * 0.5, n: i, on: i % 3 == 0});
		g.ref(3).value.x = 100;
		g.ref(4).value.x += 1.5;
		g.ref(5).value.n++;
		++g.ref(6).value.n;
		var t = 0.0;
		for (i in 0...g.length)
			t += g[i].x + g[i].n + (g[i].on ? 1000 : 0);
		return t;
	}

	// whole elements: read (a copy), written, iterated
	public static function whole():Float {
		var g = new Grow<P>();
		for (i in 0...10)
			g.push({x: i, n: -i, on: false});
		var a = g[2];
		a.x = 50;
		var b:P = {x: 7, n: 8, on: true};
		g[1] = b;
		b.n = 99;
		var t = 0.0;
		for (p in g)
			t += p.x * 2 + p.n + (p.on ? 10 : 0);
		return t + a.x;
	}

	// a Slice of a Grow, Scope.slice, a Fixed as a field and copied
	public static function views():Float {
		var g = new Grow<P>();
		for (i in 0...5)
			g.push({x: i, n: i, on: true});
		var s = g.slice();
		s[1].n = 40;
		var z:Slice<P> = Scope.slice(3);
		z[2].x = 2.5;
		var h = new Holder(1);
		h.two[1].n = 6;
		var f = h.two;
		f[1].n = 7;
		return g[1].n + z[2].x + z[0].n + h.two[1].n * 100 + f[1].n * 1000;
	}

	// an image and back
	public static function image():Float {
		var g = new Grow<P>();
		for (i in 0...4)
			g.push({x: i + 0.25, n: i * 3, on: i == 2});
		var b = Image.of(g);
		var h = new Grow<P>();
		var ok = Image.load(b, h);
		var t = 0.0;
		for (p in h)
			t += p.x + p.n + (p.on ? 100 : 0);
		return (ok ? t : -1) + b.length * 1000;
	}
}

class ScopedSoa {
	static function main() {
		trace(Code.fields());
		trace(Code.whole());
		trace(Code.views());
		trace(Code.image());
	}
}
