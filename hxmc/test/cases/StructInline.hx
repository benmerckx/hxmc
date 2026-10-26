// Struct values (docs/interop.md, "Struct values") through Haxe's inliner:
// an argument of an inline function is the function's own copy, as for a
// call. Haxe passes a local (or a field) argument into the inlined body as
// itself; where the body writes through a struct parameter (a field, a
// compound assignment, an increment, the parameter passed on as a mutable
// abstract `this`), the inliner copies it into a temporary first
// (Inline.copyArgumentHook, hxmc/src/hxmc/ir/CInterop.hx). The analyzer
// keeps such copies, and user copies (`var t = s`), copies: neither fused
// into their use nor replaced by their source (AnalyzerTexpr.keepCopyHook;
// StructInlineOpt runs this main, inline, with @:analyzer(optimize)).
@:hxmc.struct @:publicFields class SV {
	var x:Float;
	var y:Float;

	function new(x = 0.0, y = 0.0) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.struct @:publicFields class SBox {
	var lo:SV;
	var hi:SV;
	var n:Int;

	function new(lo:SV, hi:SV) {
		this.lo = lo;
		this.hi = hi;
		n = 0;
	}
}

class SHolder {
	public var v:SV;
	public var box:SBox;

	public function new() {
		v = new SV(7, 8);
		box = new SBox(new SV(1, 1), new SV(2, 2));
	}
}

// a mutable abstract over a struct: `this` in its inline methods
@:forward(x, y)
abstract MV(SV) {
	public inline function new(x:Float, y:Float)
		this = new SV(x, y);

	// writes a field of `this`: the method's own copy, as without inline
	public inline function bumped():Float {
		this.x += 1;
		return this.x;
	}

	// reads only: no copy needed
	public inline function sum():Float
		return this.x + this.y;

	// assigns `this` itself: Haxe's inline abstract semantics, the caller's
	// variable changes
	public inline function reset():Void
		this = new SV(0, 0);

	// passes `this` on to a mutating inline method
	public inline function twice():Float {
		bumped();
		return (cast this : MV).bumped();
	}

	// a mutating method on a struct parameter
	public static inline function scaleX(v:MV, k:Float):Float {
		v.raw().x *= k;
		return v.x;
	}

	inline function raw():SV
		return this;
}

// the immutable shape of the shader math types (@hxmc/gfx's Vec3)
@:forward(x, y)
abstract FV(FVData) {
	public inline function new(x:Float, y:Float)
		this = new FVData(x, y);

	@:op(A + B) static inline function add(a:FV, b:FV):FV
		return new FV(a.x + b.x, a.y + b.y);

	public inline function len2():Float
		return this.x * this.x + this.y * this.y;
}

@:hxmc.struct final class FVData {
	public final x:Float;
	public final y:Float;

	public inline function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

class StructInline {
	static inline function bump(v:SV):Float {
		v.x += 1;
		return v.x;
	}

	static inline function setY(v:SV, y:Float):Float {
		v.y = y;
		return v.x + v.y;
	}

	static inline function inc(v:SV):Float {
		v.x++;
		++v.y;
		return v.x + v.y;
	}

	static inline function replace(v:SV):Float {
		v = new SV(50, 60);
		return v.x;
	}

	static inline function nested(b:SBox):Float {
		b.lo.x = 100;
		b.n += 5;
		return b.lo.x + b.n;
	}

	// passes the parameter on to another inline function that writes it
	static inline function outer(v:SV):Float {
		var r = bump(v);
		return r + v.x;
	}

	// writes its parameter, then passes it on
	static inline function outerWrites(v:SV):Float {
		v.y = 9;
		return bump(v) + v.y;
	}

	// reads only: the argument is used in place
	static inline function len(v:SV):Float
		return v.x * v.x + v.y * v.y;

	// a write in only one branch
	static inline function maybe(v:SV, c:Bool):Float {
		if (c) v.x = -1;
		return v.x;
	}

	// a write inside a loop, read once
	static inline function loopBump(v:SV, n:Int):Void {
		for (_ in 0...n)
			v.x += 2;
	}

	// not inline: Mir's inliner and Sroa take it (a copy too)
	static function bumpCall(v:SV):Float {
		v.x += 1;
		return v.x;
	}

	static function show(v:SV):String
		return '(${v.x}, ${v.y})';

	// inline: StructInlineOpt inlines it into a function the analyzer optimizes
	public static inline function main() {
		// a local argument
		var a = new SV(1, 0);
		var r = bump(a);
		trace(a.x, r);
		trace(setY(a, 5), show(a));
		trace(inc(a), show(a));
		trace(replace(a), show(a));
		loopBump(a, 3);
		trace(show(a));
		trace(maybe(a, true), maybe(a, false), show(a));
		trace(len(a));
		trace(bumpCall(a), bumpCall(a), show(a));

		// nested struct fields
		var b = new SBox(new SV(1, 2), new SV(3, 4));
		trace(nested(b), show(b.lo), b.n);

		// an object's field as the argument
		var h = new SHolder();
		trace(bump(h.v), show(h.v));
		trace(nested(h.box), show(h.box.lo), h.box.n);

		// inline through inline
		var c = new SV(10, 20);
		trace(outer(c), show(c));
		trace(outerWrites(c), show(c));

		// an abstract over a struct: `this`
		var m = new MV(3, 4);
		trace(m.bumped(), m.x);
		trace(m.twice(), m.x);
		trace(m.sum());
		trace(MV.scaleX(m, 10), m.x);
		var m2 = m;
		m2.reset();
		trace(m.x, m.y, m2.x, m2.y);

		// the immutable math types
		var p = new FV(1, 2);
		var q = p + p;
		trace(q.x, q.y, (p + q).len2(), p.x);

		// the analyzer: a copy stays a copy
		var s = new SV(1, 1);
		var t = s;
		t.x = 42;
		trace(show(s), show(t));
		var u = s;
		s.y = 7;
		trace(show(u), show(s));
		var w = h.v;
		w.x = 3;
		trace(show(w), show(h.v));
		var k = s;
		s = new SV(5, 5);
		trace(show(k), show(s));
		var f = s;
		f.x = 99;
		trace(show(s));
	}
}
