import haxe.io.Bytes;
import hxmc.NativeGc;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Float32;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// Checked spans (docs/interop.md, "Spans"): views of memory that exist only
// in GC-free code, made by GC code only as arguments of a call of a GC-free
// function. Element access by type (bytes, Int, Float, Float32, structs in
// place), sub-views, reinterpretation, blit (overlapping too), fill, a Span
// passed as a ReadOnlySpan, Bytes and IoBuffers lent for one call (ranges
// too: a bad one throws OutsideBounds in the caller), several in one call,
// a span returned as a sub-view of a parameter, and the addresses of a
// Bytes' span taken after every argument: a later argument that collects
// moves the Bytes first.
@:hxmc.struct @:publicFields class P {
	var x:Int;
	var y:Float;
}

@:hxmc.gcfree class K {
	public static function sum(s:ReadOnlySpan<UInt8>):Int {
		var t = 0;
		for (i in 0...s.length)
			t += s[i];
		return t;
	}

	// (a sub-view of a parameter, returned to GC-free code)
	static function middle(s:ReadOnlySpan<UInt8>):ReadOnlySpan<UInt8>
		return s.sub(1, s.length - 2);

	public static function sumMiddle(s:ReadOnlySpan<UInt8>):Int
		return sum(middle(s));

	public static function bytes(s:Span<UInt8>):Int {
		for (i in 0...s.length)
			s[i] = i * 7;
		s[3] = s[3] + 100;
		var t = s.sub(2, 4);
		t.fill(0, 2, 9);
		s.blit(0, s.sub(4, 2), 0, 2);
		// (overlapping, both ways)
		s.blit(9, s, 8, 4);
		s.blit(4, s, 5, 3);
		var w:Span<Int> = s.reinterpret();
		return w.length * 1000 + sum(s) % 1000;
	}

	public static function words(s:Span<UInt8>):Int {
		var w:Span<Int> = s.reinterpret();
		for (i in 0...w.length)
			w[i] = (i + 1) * 0x01010101;
		return w[1] + s[4];
	}

	public static function floats(s:Span<UInt8>):Float {
		var d:Span<Float> = s.reinterpret(), f:Span<Float32> = s.sub(16, 8).reinterpret();
		d[0] = 1.5;
		f[0] = 0.25;
		f[1] = (f[0] : Float) * 3;
		return d[0] + f[1] + d.length + f.length;
	}

	public static function points(s:Span<P>):Float {
		for (i in 0...s.length) {
			s[i].x = i;
			s[i].y = i / 2;
		}
		var p = s[1];
		p.x = 100;
		s[2] = p;
		var sum = 0.0;
		for (i in 0...s.length)
			sum += s[i].x + s[i].y;
		return sum;
	}

	public static function copy(dst:Span<UInt8>, src:ReadOnlySpan<UInt8>):Int {
		dst.blit(0, src, 0, src.length);
		return sum(dst);
	}

	public static function two(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>, n:Int):Int
		return sum(a) * 1000 + sum(b) + n;
}

class Spans {
	// (allocates and collects: moves the young Bytes)
	static function churn(n:Int):Int {
		var junk = [for (i in 0...n) "x" + i];
		NativeGc.collect(true);
		return junk.length;
	}

	static function main() {
		var b = Bytes.ofString("abcdef");
		trace(K.sum(ReadOnlySpan.ofBytes(b)), K.sum(ReadOnlySpan.ofBytes(b, 2)), K.sum(ReadOnlySpan.ofBytes(b, 1, 2)), K.sumMiddle(ReadOnlySpan.ofBytes(b)));
		try trace(K.sum(ReadOnlySpan.ofBytes(b, 4, 3))) catch (e:haxe.io.Error) trace("range", e);
		try trace(K.sum(ReadOnlySpan.ofBytes(b, -1))) catch (e:haxe.io.Error) trace("range", e);
		var buf = IoBuffer.alloc(16);
		trace(K.bytes(Span.ofIoBuffer(buf)), [for (i in 0...16) buf.get(i)]);
		trace(K.words(Span.ofIoBuffer(buf)), buf.getInt32(12));
		var fb = IoBuffer.alloc(24);
		trace(K.floats(Span.ofIoBuffer(fb)), fb.getDouble(0));
		fb.free();
		var pb = IoBuffer.alloc(16 * 4);
		trace(K.points(Span.unsafeOf((cast pb.ptr : Ptr<P>), 4)));
		var copy = Bytes.alloc(6);
		trace(K.copy(Span.ofBytes(copy), ReadOnlySpan.ofBytes(b)), copy.toString());
		// (the arguments first, then the spans' addresses: the Bytes is young, the collection moves it)
		var young = Bytes.ofString("young");
		trace(K.two(ReadOnlySpan.ofBytes(young), ReadOnlySpan.ofIoBuffer(buf, 0, 4), churn(1000)));
		trace(K.two(ReadOnlySpan.ofBytes(Bytes.ofString("made") ), ReadOnlySpan.ofBytes(young), churn(10)));
		buf.free();
		pb.free();
	}
}
