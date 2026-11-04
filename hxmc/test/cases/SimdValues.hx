import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.simd.*;
import hxmc.unsafe.UInt8;

// Where hxmc.simd's vectors live (docs/plans/simd.md, "Vectors as values"):
// locals and phis in vector registers, fields of structs and classes,
// statics, results and arguments of calls (through memory, as struct
// values), boxed where a reference is needed (an Array's element, a type
// parameter, Dynamic, Null), closures; more live vectors than registers
// (spills), vectors live across calls; kernels over spans (every load and
// store width, checked). Each result printed as its four 32-bit words: the
// same on every back end and in the scalar implementation.
@:hxmc.struct class Particle {
	public var pos:F32x4;
	public var vel:F32x4;
	public var id:Int;

	public inline function new(pos:F32x4, vel:F32x4, id:Int) {
		this.pos = pos;
		this.vel = vel;
		this.id = id;
	}
}

class Holder {
	public var v:I32x4;
	public var p:Particle;

	public function new(v:I32x4, p:Particle) {
		this.v = v;
		this.p = p;
	}
}

class SimdValues {
	static var counter:I32x4 = I32x4.make(1, 2, 3, 4);

	static function println(s:String) {
		#if js
		js.Syntax.code("console.log({0})", s);
		#else
		Sys.println(s);
		#end
	}

	static function hex(x:Int):String
		return StringTools.hex(x, 8).toLowerCase();

	static function words(v:V128):String
		return hex(v.w0) + " " + hex(v.w1) + " " + hex(v.w2) + " " + hex(v.w3);

	static function show(name:String, v:V128)
		println(name + ": " + words(v));

	// (not inlined: vectors as arguments and results of calls)
	@:noInline static function step(p:Particle, dt:F32x4):Particle
		return new Particle(p.vel.mulAdd(dt, p.pos), p.vel * F32x4.splat(0.5), p.id + 1);

	@:noInline static function twice(v:I32x4):I32x4
		return v + v;

	static function id<T>(x:T):T
		return x;

	@:noInline static function opaque(x:Int):Int
		return x * 3 + 1;

	// twenty vectors live at once: more than the vector registers of x86-64
	// (16) and of arm64's caller-saved ones (24)
	static function pressure(seed:Int):I32x4 {
		var a0 = I32x4.splat(seed), a1 = a0 + I32x4.splat(1), a2 = a1 * a1, a3 = a2 ^ a0, a4 = a3 + a2, a5 = a4 * a1, a6 = a5 - a3, a7 = a6 + a6,
			a8 = a7 ^ a2, a9 = a8 * a4, a10 = a9 + a1, a11 = a10 * a3, a12 = a11 - a0, a13 = a12 ^ a9, a14 = a13 + a5, a15 = a14 * a6,
			a16 = a15 + a7, a17 = a16 ^ a11, a18 = a17 * a2, a19 = a18 + a12;
		// each used again after a call: live across it
		var k = opaque(seed);
		return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19 + I32x4.splat(k);
	}

	// a vector live across a call in a loop
	static function acrossCalls(n:Int):I32x4 {
		var acc = I32x4.make(1, -1, 7, 0x40000000);
		for (i in 0...n)
			acc = acc * I32x4.splat(3) + I32x4.splat(opaque(i));
		return acc;
	}

	// ---- kernels over spans

	// out[i] = clamp(a[i] * gain + b[i], -1, 1) over float32 samples, the tail scalar
	@:hxmc.kernel static function mix(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>, out:Span<UInt8>, n:Int, gain:Float):Void {
		var g = F32x4.splat(gain), lo = F32x4.splat(-1), hi = F32x4.splat(1);
		var i = 0;
		while (i + 4 <= n) {
			var x = F32x4.loadSpan(a, i * 4).mulAdd(g, F32x4.loadSpan(b, i * 4));
			x.clamp(lo, hi).storeSpan(out, i * 4);
			i += 4;
		}
		while (i < n) {
			var x = F32x4.loadSpan32(a, i * 4).mulAdd(g, F32x4.loadSpan32(b, i * 4));
			x.clamp(lo, hi).storeSpan32(out, i * 4);
			i++;
		}
	}

	// the sum of n bytes, 16 at a time, then 8, then one by one
	@:hxmc.kernel static function byteSum(s:ReadOnlySpan<UInt8>, n:Int):Int {
		var acc = U32x4.zero();
		var i = 0;
		while (i + 16 <= n) {
			var v = U8x16.loadSpan(s, i);
			var w = U16x8.extendLow(v) + U16x8.extendHigh(v);
			acc = acc + U32x4.extendLow(w) + U32x4.extendHigh(w);
			i += 16;
		}
		if (i + 8 <= n) {
			var v = U8x16.loadSpan64(s, i);
			var w = U16x8.extendLow(v);
			acc = acc + U32x4.extendLow(w) + U32x4.extendHigh(w);
			i += 8;
		}
		var t = acc.asI32x4().sum();
		while (i < n) {
			t += s[i];
			i++;
		}
		return t;
	}

	// 8 bytes of each row interleaved: a store of the low half
	@:hxmc.kernel static function interleave(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>, out:Span<UInt8>):Void {
		var x = U8x16.loadSpan64(a, 0), y = U8x16.loadSpan64(b, 0);
		x.shuffle(y, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23).storeSpan(out, 0);
		x.shuffle(y, 4, 20, 5, 21, 6, 22, 7, 23, 0, 0, 0, 0, 0, 0, 0, 0).storeSpan64(out, 16);
	}

	static function main() {
		// fields of structs and classes, statics
		var p = new Particle(F32x4.make(0, 1, 2, 3), F32x4.make(1, -2, 0.5, 4), 7);
		for (k in 0...3)
			p = step(p, F32x4.splat(0.25));
		show("struct pos", p.pos);
		show("struct vel", p.vel);
		println("struct id: " + p.id);
		var h = new Holder(I32x4.make(5, 6, 7, 8), p);
		h.v = h.v * I32x4.splat(-3);
		h.p.pos = h.p.pos + h.p.vel;
		show("class field", h.v);
		show("class struct field", h.p.pos);
		counter = twice(counter) + I32x4.splat(1);
		counter = twice(counter);
		show("static", counter);

		// boxed: an array's elements, a type parameter, Dynamic, Null
		var arr:Array<I32x4> = [];
		for (k in 0...5)
			arr.push(I32x4.make(k, k * k, -k, k << 20));
		var sum = I32x4.zero();
		for (x in arr)
			sum = sum + x;
		show("array", sum);
		show("array[3]", arr[3]);
		show("generic", id(I32x4.splat(9)) + id(arr[2]));
		var d:Dynamic = F32x4.make(1.5, 2.5, 3.5, 4.5);
		var back:F32x4 = d;
		show("dynamic", back * F32x4.splat(2));
		var n:Null<I16x8> = null;
		println("null: " + (n == null));
		n = I16x8.splat(-7);
		var nn:I16x8 = n;
		show("null set", nn + I16x8.splat(1));
		var f = (a:I32x4, b:I32x4) -> a * b + I32x4.splat(1);
		show("closure", f(I32x4.make(2, 3, 4, 5), I32x4.splat(10)));

		// registers
		show("pressure", pressure(opaque(2)));
		show("across calls", acrossCalls(10));

		// kernels over spans
		var n = 11;
		var a = Bytes.alloc(n * 4), b = Bytes.alloc(n * 4), out = Bytes.alloc(n * 4);
		for (i in 0...n) {
			a.setFloat(i * 4, i * 0.375 - 1.5);
			b.setFloat(i * 4, 0.25 - i * 0.0625);
		}
		mix(ReadOnlySpan.ofBytes(a), ReadOnlySpan.ofBytes(b), Span.ofBytes(out), n, 0.8);
		var mixed = [for (i in 0...n) hex(out.getInt32(i * 4))];
		println("mix: " + mixed.join(" "));
		var bytes = Bytes.alloc(61);
		for (i in 0...61)
			bytes.set(i, (i * 37 + 11) & 0xff);
		var expect = 0;
		for (i in 0...61)
			expect += bytes.get(i);
		println("byteSum: " + byteSum(ReadOnlySpan.ofBytes(bytes), 61) + " (" + expect + ")");
		var il = Bytes.alloc(24);
		interleave(ReadOnlySpan.ofBytes(bytes, 0, 8), ReadOnlySpan.ofBytes(bytes, 8, 8), Span.ofBytes(il));
		println("interleave: " + il.toHex());
	}
}
