import haxe.io.Bytes;
import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Float32;
import hxmc.unsafe.Int16;
import hxmc.unsafe.Int8;
import hxmc.unsafe.Struct;
import hxmc.unsafe.UInt16;
import hxmc.unsafe.UInt8;

// Spans that behave the same on hxmc and, over Bytes, on the other targets
// (docs/interop.md, "Spans on other targets"; PortableCheck runs this case
// on Eval and JavaScript and compares their output with this golden file):
// every scalar element type through reinterpret, wrapping stores, sub, blit
// (overlapping), fill, struct elements written in place, Struct's sizes,
// the atomic accesses, and a Bytes' range checked in the caller.
@:hxmc.struct @:publicFields class Px {
	var x:Int;
	var y:Float;
	var tag:UInt8;

	function new() {}
}

@:hxmc.kernel class Kp {
	// values of each element type into out's Ints, from k
	public static function scalars(s:Span<UInt8>, out:Span<UInt8>):Int {
		var o:Span<Int> = out.reinterpret();
		for (i in 0...s.length)
			s[i] = i * 37 + 200;
		var k = 0;
		o[k++] = s[1];
		var i8:Span<Int8> = s.reinterpret();
		o[k++] = i8[1];
		var u16:Span<UInt16> = s.reinterpret(), i16:Span<Int16> = s.reinterpret();
		o[k++] = u16[3];
		o[k++] = i16[3];
		o[k++] = u16.length;
		var w:Span<Int> = s.reinterpret(), u:Span<UInt> = s.reinterpret();
		o[k++] = w[1];
		var big:Float = u[1];
		o[k++] = Std.int(big / 1000);
		var f:Span<Float32> = s.sub(0, 8).reinterpret(), d:Span<Float> = s.sub(8, 8).reinterpret();
		f[1] = 0.1;
		o[k++] = Std.int((f[1] : Float) * 1e9);
		d[0] = 2.75;
		o[k++] = Std.int(d[0] * 4);
		var l:Span<I64> = s.reinterpret();
		l[1] = ((5 : I64) << 33) + 7;
		o[k++] = (l[1] >> 33).toInt() * 100 + (l[1] & 0xFF).toInt();
		var b:Span<Bool> = s.sub(0, 2).reinterpret();
		b[0] = true;
		b[1] = false;
		o[k++] = (b[0] ? 10 : 0) + (b[1] ? 1 : 0) + s[0];
		// (stores wrap as C's conversions do)
		s[2] = 300;
		i8[3] = 200;
		u16[2] = 70000;
		o[k++] = s[2] * 1000000 + (i8[3] : Int) * 1000 + (u16[2] : Int);
		return k;
	}

	public static function views(s:Span<UInt8>):Int {
		for (i in 0...s.length)
			s[i] = i;
		var t = s.sub(2, 6);
		t.fill(1, 2, 99);
		s.blit(10, s, 8, 4);
		s.blit(4, s, 5, 4);
		var r:ReadOnlySpan<UInt8> = s.sub(12, 4);
		var sum = 0;
		for (i in 0...s.length)
			sum = sum * 3 + s[i];
		return sum % 1000000 + r[3] * 1000000 + t.length * 100000000;
	}

	public static function structs(s:Span<UInt8>):Int {
		var p:Span<Px> = s.reinterpret();
		for (i in 0...p.length) {
			p[i] = new Px();
			p[i].x = i * 10;
			p[i].y = i / 4;
			p[i].tag = 250 + i;
		}
		p[1].x += 5;
		p.blit(0, p.sub(2, 2), 0, 2);
		var sum = 0.0;
		for (i in 0...p.length)
			sum += p[i].x + p[i].y + (p[i].tag : Int);
		return Std.int(sum * 4) + p.length * 100000 + Struct.sizeOf(Px) * 10000000;
	}

	public static function sum(s:ReadOnlySpan<UInt8>):Int {
		var t = 0;
		for (i in 0...s.length)
			t += s[i];
		return t;
	}

	public static function atomics(s:Span<UInt8>):Int {
		var w:Span<Int> = s.reinterpret();
		w.store(0, 41);
		var seen = w.compareExchange(0, 41, 42);
		var miss = w.compareExchange(0, 41, 43);
		var ro:ReadOnlySpan<Int> = w;
		return ro.load(0) * 10000 + seen * 100 + miss;
	}
}

class SpanPortable {
	static function main() {
		var s = Bytes.alloc(16), out = Bytes.alloc(64);
		var n = Kp.scalars(Span.ofBytes(s), Span.ofBytes(out));
		trace("scalars", [for (k in 0...n) out.getInt32(k * 4)]);
		trace("views", Kp.views(Span.ofBytes(Bytes.alloc(16))));
		trace("structs", Kp.structs(Span.ofBytes(Bytes.alloc(96))));
		trace("atomics", Kp.atomics(Span.ofBytes(Bytes.alloc(8))));
		var b = Bytes.ofString("abcdef");
		try trace(Kp.sum(ReadOnlySpan.ofBytes(b, 4, 3))) catch (e:haxe.io.Error) trace("range", e);
		trace("sub", Kp.sum(ReadOnlySpan.ofBytes(b, 2)), Kp.sum(ReadOnlySpan.ofBytes(b, 1, 2)));
	}
}
