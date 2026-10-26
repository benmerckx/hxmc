import hxmc.unsafe.*;

// @:hxmc.struct values (docs/interop.md, "Struct values"): locals,
// parameters and results are copies; fields of structs and of objects hold
// them inline (an object's moves with it at each collection: the corpus runs
// with a small nursery); statics; memory behind a Ptr or in a Slice;
// equality; virtual and interface calls; an abstract with operators over a
// struct; try/catch; boxes where a reference is needed (Dynamic, Array
// elements, type parameters, Null<T>, enum arguments, structural types);
// closures taking and returning structs.
@:hxmc.struct @:publicFields class V2 {
	var x:Float;
	var y:Float;

	inline function new(x = 0.0, y = 0.0) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.struct @:publicFields class Rect {
	var min:V2;
	var max:V2;
	var tag:Int;
	var on:Bool;

	function new(a:V2, b:V2, tag:Int) {
		min = a;
		max = b;
		this.tag = tag;
		on = tag > 0;
	}
}

@:hxmc.struct @:publicFields class Mixed {
	var b:Int8;
	var s:UInt16;
	var f:Float32;
	var l:Int64;
	var p:Ptr;

	function new() {}
}

// an abstract over a struct with operators, as the shader math types
@:forward(x, y)
abstract Vec(V2) {
	public inline function new(x:Float, y:Float)
		this = new V2(x, y);

	@:op(A + B) static inline function add(a:Vec, b:Vec):Vec
		return new Vec(a.x + b.x, a.y + b.y);

	@:op(A * B) static inline function scale(a:Vec, s:Float):Vec
		return new Vec(a.x * s, a.y * s);

	public inline function dot(b:Vec):Float
		return this.x * b.x + this.y * b.y;
}

class Body {
	public var name:String;
	public var pos:V2;
	public var box:Rect;
	public var mass:Float;

	public function new(name:String, x:Float, y:Float) {
		this.name = name;
		pos = new V2(x, y);
		box = new Rect(new V2(x - 1, y - 1), new V2(x + 1, y + 1), name.length);
		mass = 1;
	}

	public function center():V2
		return pos;
}

class Heavy extends Body {
	override public function center():V2
		return new V2(pos.x * 10, pos.y * 10);
}

interface Shape {
	function area(r:Rect):Float;
	function corner(r:Rect):V2;
}

class Boxes implements Shape {
	public function new() {}

	public function area(r:Rect):Float
		return (r.max.x - r.min.x) * (r.max.y - r.min.y);

	public function corner(r:Rect):V2
		return r.max;
}

enum Event {
	Moved(to:V2);
	Stopped;
}

typedef Labeled = {name:String, at:V2};

class StructValues {
	static function firstOf<T>(xs:Array<T>):T
		return xs[0];

	static function apply(f:V2->V2, v:V2):V2
		return f(v);

	static var origin = new V2(0.5, -0.5);
	static var last:Rect;

	static function sum(v:V2):Float
		return v.x + v.y;

	// a parameter is the callee's own copy
	static function bump(v:V2):Float {
		v.x += 100;
		return v.x;
	}

	static function mid(a:V2, b:V2):V2
		return new V2((a.x + b.x) / 2, (a.y + b.y) / 2);

	static function grow(r:Rect, d:Float):Rect {
		var g = r;
		g.min.x -= d;
		g.min.y -= d;
		g.max = new V2(r.max.x + d, r.max.y + d);
		return g;
	}

	static function fib(v:V2, n:Int):V2
		return n == 0 ? v : fib(new V2(v.y, v.x + v.y), n - 1);

	static function show(v:V2):String
		return '(${v.x}, ${v.y})';

	static function showRect(r:Rect):String
		return '[${show(r.min)} ${show(r.max)} ${r.tag} ${r.on}]';

	static function main() {
		// locals: copies
		var a = new V2(1, 2);
		var b = a;
		b.x = 10;
		trace(show(a), show(b), sum(a), sum(new V2()));
		trace(bump(a), show(a));
		var m = mid(a, b);
		trace(show(m), show(mid(m, origin)));
		a = m;
		m.y = 99;
		trace(show(a), show(m), a == m, a != m, a == new V2(5.5, 2), new V2(Math.NaN, 0) == new V2(Math.NaN, 0));
		// nested structs
		var r = new Rect(a, b, 7);
		var g = grow(r, 0.5);
		trace(showRect(r), showRect(g));
		g.min = r.max;
		r.max.y = -1;
		trace(showRect(r), showRect(g), r.min == g.min, r.min.x == a.x);
		trace(show(fib(new V2(0, 1), 20)));
		// conditional values, loops
		var pick = r.tag > 3 ? r.min : r.max;
		var acc = new V2();
		for (i in 0...5) {
			var step = new V2(i, i * i);
			acc = mid(acc, step);
			acc.x += 1;
		}
		trace(show(pick), show(acc));
		// statics
		trace(show(origin));
		origin.x = 3;
		last = grow(r, 1);
		origin = last.max;
		trace(show(origin), showRect(last));
		// objects: fields inline, through collections
		var bodies = [for (i in 0...200) i % 3 == 0 ? new Heavy("h" + i, i, -i) : new Body("b" + i, i, i / 2)];
		var junk = [];
		for (round in 0...20) {
			for (k in 0...bodies.length) {
				var o = bodies[k];
				o.pos.x += 1;
				o.box.max.y += o.pos.x;
				if (k % 7 == 0) o.box = grow(o.box, 0.25);
				junk.push([for (j in 0...10) "j" + j + round]);
			}
			if (junk.length > 500) junk = [];
		}
		var total = 0.0, boxes = 0.0;
		for (o in bodies) {
			var c = o.center();
			total += c.x + c.y;
			boxes += o.box.max.y - o.box.min.x;
		}
		trace(total, boxes, show(bodies[3].pos), showRect(bodies[7].box), bodies[5].box.on);
		var shape:Shape = new Boxes();
		trace(shape.area(bodies[9].box), show(shape.corner(new Rect(new V2(), new V2(4, 8), 0))));
		// memory behind a Ptr
		Arena.scoped(ar -> {
			var p = ar.make(Rect);
			p.value = r;
			var q = ar.makeArray(V2, 4);
			for (i in 0...4)
				q[i] = new V2(i, -i);
			q[2].y = 42;
			var c = q[3];
			c.x = 77;
			p.value.min = q[2];
			trace(showRect(p.value), show(q[2]), show(q[3]), show(c));
			var mx = ar.make(Mixed);
			mx.value.b = -5;
			mx.value.s = 65535;
			mx.value.f = 1.5;
			mx.value.l = 1 << 20;
			var my = mx.value;
			my.b++;
			trace(my.b, my.s, my.f, haxe.Int64.toStr(my.l), mx.value.b, my == mx.value);
			// a Slice of structs: elements inline, reached in place
			var s = ar.slice(V2, 8);
			for (i in 0...s.length)
				s[i] = new V2(i, 2 * i);
			s[3].x = -1;
			var t = s.sub(2, 3);
			t[0].y += 100;
			var e = t[1];
			e.y = 0;
			var err = try {
				s[8].x;
				"no error";
			} catch (m:String) m;
			trace(s.length, show(s[2]), show(s[3]), show(e), t.length, show(t[2]), err);
		});
		// the operators of an abstract over a struct
		var u = new Vec(1, 2), w = new Vec(3, 4);
		var z = (u + w) * 2;
		trace(z.x, z.y, u.dot(w), (u + u).dot(w * 0.5));
		// try/catch around struct locals
		var t = new V2(1, 1);
		try {
			t.x = 5;
			if (t.x > 2) throw "big";
			t.y = 9;
		} catch (e:String) {
			t.y = -9;
		}
		trace(show(t));
		// boxes: copies where a reference is needed
		var arr = [new V2(1, 2), new V2(3, 4)];
		arr.push(a);
		var e0 = arr[0];
		e0.x = 50;
		arr[1] = e0;
		var sumX = 0.0;
		for (v in arr)
			sumX += v.x;
		trace(arr.length, show(arr[0]), show(arr[1]), show(arr[2]), sumX, show(firstOf(arr)));
		var d:Dynamic = new V2(7, 8);
		var back:V2 = d;
		var n:Null<V2> = null;
		var n2:Null<V2> = back;
		trace(show(back), n == null, n2 == null, show(n2), Std.string(d) != "");
		var o:Dynamic = "not a V2";
		trace(Std.isOfType(d, V2), Std.isOfType(o, V2), Type.getClassName(Type.getClass(d)), show(cast(d, V2)));
		var m = new Map<String, V2>();
		m.set("a", new V2(9, 10));
		var got:V2 = m.get("a");
		got.y = 0;
		trace(show(m.get("a")), show(got), m.exists("b"));
		var evs = [Moved(new V2(1, 1)), Stopped, Moved(new V2(2, 3))];
		var far = new V2();
		for (ev in evs)
			switch ev {
				case Moved(to): far = mid(far, to);
				case Stopped: far.x += 10;
			}
		var lab:Labeled = {name: "p", at: new V2(4, 5)};
		trace(show(far), lab.name, show(lab.at), "s" + new V2(1, 2) != "");
		// closures with struct parameters and results
		var shift = (v:V2) -> new V2(v.x + 1, v.y - 1);
		function twice(v:V2):V2
			return shift(shift(v));
		var fs:Array<V2->V2> = [shift, twice, v -> mid(v, origin)];
		var r2 = new V2(0, 0);
		for (f in fs)
			r2 = f(r2);
		trace(show(twice(new V2(5, 5))), show(apply(shift, new V2(1, 1))), show(apply(StructValues.fib.bind(_, 3), new V2(1, 1))), show(r2));
	}
}
