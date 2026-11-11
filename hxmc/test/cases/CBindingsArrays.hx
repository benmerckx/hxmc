import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.USize;

// Arrays at typed bindings (docs/interop.md, "Typed bindings"):
// ReadOnlySpan.ofArray(a) copies an Array's structs or scalars into C memory
// for the call, Span.ofArray(a) back into the Array after it, so GC code
// passes many CGRects without raw memory. make header-check checks them.
// define: hxmc.strict
@:hxmc.struct @:hxmc.cname("struct ca_rect") @:publicFields class Rect {
	var x:Float;
	var y:Float;
	var w:Float;
	var h:Float;

	inline function new(x:Float, y:Float, w:Float, h:Float) {
		this.x = x;
		this.y = y;
		this.w = w;
		this.h = h;
	}
}

@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("CBindingsArrays.h") extern class A {
	@:hxmc.len(r, n) static function ca_area(r:ReadOnlySpan<Rect>, n:USize):Float;
	@:hxmc.len(r, n) static function ca_grow(r:Span<Rect>, n:USize, d:Float):Void;
	@:hxmc.len(v, n) static function ca_max(v:ReadOnlySpan<Int>, n:Int):Int;
	@:hxmc.len(v, n) static function ca_iota(v:Span<Float>, n:Int):Void;
}

class CBindingsArrays {
	static function main() {
		var rects = [new Rect(0, 0, 2, 3), new Rect(1, 1, 4, 5), new Rect(2, 2, 1, 1)];
		trace(A.ca_area(ReadOnlySpan.ofArray(rects), rects.length));
		A.ca_grow(Span.ofArray(rects), 2, 0.5);
		trace([for (r in rects) '${r.x},${r.y},${r.w},${r.h}'].join(" "));
		trace(A.ca_max(ReadOnlySpan.ofArray([3, 9, -2, 7]), 4), A.ca_area(ReadOnlySpan.ofArray([]), 0));
		var v = [for (i in 0...5) 0.0];
		A.ca_iota(Span.ofArray(v), v.length);
		trace(v);
		var total = 0.0;
		for (i in 0...1000)
			total += A.ca_area(ReadOnlySpan.ofArray([new Rect(0, 0, i, 1)]), 1);
		trace(total);
	}
}
