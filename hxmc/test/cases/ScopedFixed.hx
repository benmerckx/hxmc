// Fixed<T, N> (docs/plans/lowlevel.md, "Types"): N elements inline in what
// holds them (a frame, a struct, a Grow's element), a struct value; its
// elements reached through a view of the same memory.
import hxmc.scoped.*;

@:hxmc.scoped class V {
	public var x:Int;
	public var y:Int;

	public function new(x:Int, y:Int) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.scoped class Box {
	public var tag:Int;
	public var data:Fixed<Int, 4>;

	public function new(tag:Int) {
		this.tag = tag;
		data = new Fixed<Int, 4>();
	}
}

@:hxmc.scoped class Code {
	public static function fill(n:Int):Int {
		var f = new Fixed<Int, 8>();
		for (i in 0...f.length)
			f[i] = i * n;
		var t = 0;
		for (v in f)
			t += v;
		return t;
	}

	// a value: a copy is another Fixed
	public static function copies():Int {
		var a = new Fixed<Int, 3>();
		a[0] = 1;
		var b = a;
		b[0] = 5;
		return a[0] * 10 + b[0];
	}

	// struct elements, written in place
	public static function structs():Int {
		var vs = new Fixed<V, 4>();
		vs[1].x = 7;
		vs[2] = new V(1, 2);
		return vs[1].x + vs[2].y + vs[3].x;
	}

	// struct elements copied with the Fixed
	public static function structCopies():Int {
		var a = new Fixed<V, 2>();
		a[0].x = 1;
		var b = a;
		b[0].x = 5;
		return a[0].x * 10 + b[0].x;
	}

	// a Fixed inside the elements of a Grow
	public static function inGrow():Int {
		var g = new Grow<Box>();
		for (i in 0...3) {
			var b = new Box(i);
			b.data[i] = i + 1;
			g.push(b);
		}
		var t = 0;
		for (b in g)
			for (v in b.data)
				t += v * (b.tag + 1);
		return t;
	}

	// large: copied and zeroed in a loop
	public static function big():Float {
		var f = new Fixed<Float, 300>();
		f[299] = 2.5;
		var g = f;
		g[0] = 1;
		return g[299] * 2 + f[0] + f.length;
	}

	// a view is the same memory
	public static function view():Int {
		var f = new Fixed<Int, 5>();
		var s = f.view();
		s[4] = 9;
		return f[4] + s.length;
	}
}

class ScopedFixed {
	static function main() {
		trace(Code.fill(3));
		trace(Code.copies());
		trace(Code.structs());
		trace(Code.structCopies());
		trace(Code.inGrow());
		trace(Code.big());
		trace(Code.view());
	}
}
