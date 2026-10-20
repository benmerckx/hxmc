// Escape analysis (hxmc/src/hxmc/Escape.hx): class instances and anonymous
// objects that never leave their function are replaced by their fields;
// those that do (stored, returned, passed, compared, merged with another
// value, or used after a newer instance of their group) stay objects. Each
// function prints what it computes, the same either way.
class P {
	public var x:Int;
	public var y:Float;
	public var next:P;

	public function new(x:Int, y:Float) {
		this.x = x;
		this.y = y;
	}

	public function sum():Float
		return x + y;
}

class Q extends P {
	override public function sum():Float
		return x * 2 + y;
}

typedef Pair = {a:Int, b:Float};

class EscapeObjects {
	static var keep:P;
	static var calls = 0;

	@:noinline static function bump()
		calls++;

	// (a try: never inlined)
	static function take(p:P):Int {
		try {
			return p.x;
		} catch (e:Dynamic) {
			return -1;
		}
	}

	@:noinline static function mayThrow(a:Int)
		if (a > 10) throw "big " + a;

	static function pair(a:Int, b:Float):Pair
		return {a: a, b: b};

	// replaced: a field read and a method inlined
	@:noinline static function simple(a:Int):Float {
		var p = new P(a, 1.5);
		return p.sum();
	}

	// replaced: live across a call (a shadow-stack slot)
	@:noinline static function acrossCall(a:Int):Float {
		var p = new P(a, 2.0);
		bump();
		p.x++;
		bump();
		return p.x + p.y;
	}

	// replaced: two sites of one class meet at a phi
	@:noinline static function phi(c:Bool, a:Int):Float {
		var p = c ? new P(a, 1) : new P(-a, 2);
		p.y *= 3;
		return p.x * p.y;
	}

	// kept: the sites of a phi are of two classes
	@:noinline static function phiMixed(c:Bool, a:Int):Float {
		var p:P = c ? new P(a, 1) : new Q(a, 2);
		return p.sum();
	}

	// replaced: an instance carried around a loop (mandelbrot's)
	@:noinline static function loop(n:Int):Float {
		var p = new P(0, 0);
		for (i in 0...n)
			p = new P(p.x + i, p.y + 0.5);
		return p.x + p.y;
	}

	// kept: the previous instance read after the next one is made
	@:noinline static function loopOld(n:Int):Float {
		var p = new P(1, 1);
		var s = 0.0;
		for (i in 0...n) {
			var q = new P(p.x + 1, p.y * 2);
			s += p.x + q.x;
			p = q;
		}
		return s + p.y;
	}

	@:noinline static function writeAfterRead(a:Int):Int {
		var p = new P(a, 0);
		var r = p.x;
		p.x = r + 5;
		var r2 = p.x;
		p.x = 0;
		return r * 100 + r2 * 10 + p.x;
	}

	@:noinline static function twoNames(a:Int):Int {
		var p = new P(a, 0);
		var q = p;
		q.x += 3;
		p.x *= 2;
		return q.x + p.x;
	}

	// kept: stored into a global, then read through it
	@:noinline static function toGlobal(a:Int):Int {
		var p = new P(a, 0);
		keep = p;
		p.x++;
		return keep.x;
	}

	@:noinline static function returned(a:Int):P
		return new P(a, 1);

	@:noinline static function passed(a:Int):Int {
		var p = new P(a, 0);
		p.x = take(p) + 1;
		return take(p) + p.x;
	}

	// the inner object is stored into the outer one's field: kept (the outer one too)
	@:noinline static function nested(a:Int):Int {
		var p = new P(a, 0);
		var q = new P(a + 1, 0);
		p.next = q;
		q.x = 7;
		return p.next.x + p.x;
	}

	// a reference field of a new object: the write barrier goes too
	@:noinline static function refField(o:P):Float {
		var p = new P(1, 0.25);
		p.next = o;
		var r = p.next.x + p.x + p.y;
		p.next = null;
		return p.next == null ? r : -1;
	}

	@:noinline static function identity(a:Int):String {
		var p = new P(a, 0);
		var q = new P(a, 0);
		var r = p;
		return (p == q) + " " + (p == r) + " " + (p != null);
	}

	// replaced in the caller's frame across a callee that throws
	@:noinline static function thrower(a:Int):Int {
		var p = new P(a, 0);
		p.x += 1;
		mayThrow(a);
		return p.x;
	}

	// a function with a try: left alone
	@:noinline static function withTry(a:Int):Int {
		var p = new P(a, 0);
		try {
			mayThrow(a);
			p.x++;
		} catch (e:String) {
			p.x = -p.x;
		}
		return p.x;
	}

	// kept: merged with null
	@:noinline static function lastOf(n:Int):Int {
		var last:P = null;
		for (i in 0...n)
			last = new P(i, 0);
		return last == null ? -1 : last.x;
	}

	// replaced, its fields' values meeting at phis
	@:noinline static function fieldPhis(n:Int):Float {
		var p = new P(0, 0);
		for (i in 0...n) {
			if (i % 3 == 0) p.x += i else p.y += 1;
			if (i == 7) p.x = -p.x;
		}
		return p.x + p.y;
	}

	// replaced while others are allocated (and collected) around it
	@:noinline static function gcStress(n:Int):Int {
		var acc = new P(0, 0);
		var arr = [];
		for (i in 0...n) {
			arr.push(new P(i, i));
			acc.x += arr[arr.length - 1].x & 7;
			if (arr.length > 100) arr = [];
		}
		return acc.x + arr.length;
	}

	// a type test of a new object (inline: the type index is known)
	@:noinline static function typeTest(a:Int):String {
		var p:P = a > 0 ? new Q(a, 0) : new Q(-a, 1);
		return Std.isOfType(p, Q) + " " + Std.isOfType(p, P) + " " + (Std.downcast(p, Q) != null) + " " + p.sum();
	}

	// kept: read through Dynamic (the runtime)
	@:noinline static function dynamicRead(a:Int):Int {
		var d:Dynamic = new P(a, 0);
		return d.x + 1;
	}

	// anonymous objects: through an inlined function and a structure's field reads
	@:noinline static function anon(a:Int):Float {
		var o = pair(a, a / 4);
		o.a += 2;
		return o.a + o.b;
	}

	// kept: an anonymous object given to Reflect
	@:noinline static function anonReflect(a:Int):Int {
		var o = pair(a, 0);
		return Reflect.field(o, "a") + o.a;
	}

	@:noinline static function anonLoop(n:Int):Float {
		var o = pair(1, 1);
		for (i in 0...n)
			o = pair(o.a + i, o.b * 1.5);
		return o.a + o.b;
	}

	static function main() {
		Sys.println(simple(3));
		Sys.println(acrossCall(4) + " " + calls);
		Sys.println(phi(true, 2) + " " + phi(false, 2));
		Sys.println(phiMixed(true, 2) + " " + phiMixed(false, 2));
		Sys.println(loop(10));
		Sys.println(loopOld(5));
		Sys.println(writeAfterRead(2));
		Sys.println(twoNames(5));
		Sys.println(toGlobal(9) + " " + keep.x);
		Sys.println(returned(4).x);
		Sys.println(passed(6));
		Sys.println(nested(3));
		Sys.println(refField(new P(40, 0)));
		Sys.println(identity(1));
		Sys.println(thrower(3));
		try {
			Sys.println(thrower(30));
		} catch (e:String) {
			Sys.println("caught " + e);
		}
		Sys.println(withTry(5) + " " + withTry(50));
		Sys.println(lastOf(0) + " " + lastOf(6));
		Sys.println(fieldPhis(20));
		Sys.println(gcStress(100000));
		Sys.println(typeTest(5) + " " + typeTest(-5));
		Sys.println(dynamicRead(8));
		Sys.println(anon(6));
		Sys.println(anonReflect(7));
		Sys.println(anonLoop(6));
	}
}
