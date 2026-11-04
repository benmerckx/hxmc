import hxmc.simd.*;
import hxmc.unsafe.*;

// hxmc.simd's vectors in C signatures (docs/plans/simd.md, "ABIs"): C's
// native 128-bit vectors by value, in vector registers on System V and
// AAPCS64 (the eight of them, then a scalar on the stack), by address on
// Win64 with the result in xmm0; and a callback C calls with vectors
// (SimdFfi.c, built by the corpus harness with zig; WebAssembly has no C
// objects); structs with vectors in them by each ABI's rule for them; a C
// global's vectors through its symbol, whole and by their low 8 and 4 bytes.
@:hxmc.c @:hxmc.fast extern class V {
	static function v_madd(a:F32x4, b:F32x4, c:F32x4):F32x4;
	static function v_mix(k:Int, a:I32x4, d:Float, b:I32x4):I32x4;
	static function v_sum(a:F32x4, b:F64x2):Float;
	static function v_make(x:Float32, y:Float32, z:Float32, w:Float32):F32x4;
	static function v_swap(a:F64x2):F64x2;
	static function v_eight(a:I32x4, b:I32x4, c:I32x4, d:I32x4, e:I32x4, f:I32x4, g:I32x4, h:I32x4):I32x4;
}

@:hxmc.c extern class VB {
	static function v_cb(f:Ptr):Float;
	static function s_cb(f:Ptr, g:Ptr):Float;
}

@:hxmc.struct class Wrap {
	public var v:F32x4;

	public inline function new(v:F32x4)
		this.v = v;
}

@:hxmc.struct class Trio {
	public var a:I32x4;
	public var b:I32x4;
	public var c:I32x4;

	public inline function new(a:I32x4, b:I32x4, c:I32x4) {
		this.a = a;
		this.b = b;
		this.c = c;
	}
}

@:hxmc.struct class Quad {
	public var a:F32x4;
	public var b:F32x4;
	public var c:F32x4;
	public var d:F32x4;

	public inline function new(a:F32x4, b:F32x4, c:F32x4, d:F32x4) {
		this.a = a;
		this.b = b;
		this.c = c;
		this.d = d;
	}
}

// (C's layout: v at 16, d at 32, 48 bytes)
@:hxmc.struct class Mixed {
	public var k:Int;
	public var v:I32x4;
	public var d:Float;

	public inline function new(k:Int, v:I32x4, d:Float) {
		this.k = k;
		this.v = v;
		this.d = d;
	}
}

@:hxmc.c @:hxmc.fast extern class S {
	static function w_scale(a:Wrap, k:Float32):Wrap;
	static function t_rot(x:Trio, n:Int):Trio;
	static function q_add(x:Quad, y:Wrap):Quad;
	static function m_step(pre:Int, m:Mixed, w:Wrap):Mixed;
	static function m_far(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, m:Mixed):Float;
}

class SimdFfi {
	@:hxmc.callback static function back(a:F32x4, k:Int, b:F32x4):F32x4
		return a * F32x4.splat(k) + b;

	@:hxmc.callback static function backWrap(w:Wrap, m:Mixed, t:Trio):Wrap
		return new Wrap(w.v * F32x4.splat(m.k) + F32x4.make(m.d, t.a.get(0), t.b.get(1), t.c.get(2)) + m.v.toF32x4());

	@:hxmc.callback static function backQuad(q:Quad):Quad
		return new Quad(q.d, q.c, q.b, q.a * F32x4.splat(2));

	// a C global's vectors at its symbol's address
	@:hxmc.unsafe static function global():Void {
		var p = Mem.sym("v_global");
		var whole = I32x4.loadPtr(p, 16);
		var low8:I32x4 = cast Ops.load("v128.load64_zero", p, 32);
		var low4:I32x4 = cast Ops.load("v128.load32_zero", p, 4);
		(whole + low8 + low4).storePtr(p, 0);
		Ops.store("v128.store64_lane", p, 16, (I32x4.splat(-1) : V128));
		Ops.store("v128.store32_lane", p, 40, (I32x4.splat(-2) : V128));
	}

	@:hxmc.unsafe static function globalWord(k:Int):Int
		return Mem.getI32(Mem.sym("v_global"), 4 * k);

	static function main() {
		var a = F32x4.make(1, 2, 3, 4), b = F32x4.make(0.5, -1, 2, 0.25), c = F32x4.splat(10);
		Sys.println("madd: " + V.v_madd(a, b, c).toString());
		Sys.println("mix: " + V.v_mix(3, I32x4.make(1, 2, 3, 4), 100.75, I32x4.make(-1, 0, 1, 2)).toString());
		Sys.println("sum: " + V.v_sum(a, F64x2.make(0.5, -2)));
		Sys.println("make: " + V.v_make(1.5, -2, 0.25, 8).toString());
		Sys.println("swap: " + V.v_swap(F64x2.make(1.25, -3)).toString());
		var vs = [for (k in 0...8) I32x4.make(k, k * 10, k * 100, -k)];
		Sys.println("eight: " + V.v_eight(vs[0], vs[1], vs[2], vs[3], vs[4], vs[5], vs[6], vs[7]).toString());
		// (a vector live across a C call: in a register the callee may clobber, or saved)
		var keep = I32x4.make(7, 8, 9, 10);
		var m = V.v_madd(a, a, a);
		Sys.println("kept: " + (keep + I32x4.splat(1)).toString() + " " + m.toString());
		Sys.println("callback: " + VB.v_cb(Callback.addr(back)));
		// structs with vectors in them
		Sys.println("wrap: " + S.w_scale(new Wrap(a), 3).v.toString());
		var t = S.t_rot(new Trio(I32x4.make(1, 2, 3, 4), I32x4.make(10, 20, 30, 40), I32x4.make(100, 200, 300, 400)), 5);
		Sys.println("trio: " + t.a.toString() + " " + t.b.toString() + " " + t.c.toString());
		var q = S.q_add(new Quad(a, b, c, F32x4.splat(-1)), new Wrap(F32x4.make(1, 0, -1, 0.5)));
		Sys.println("quad: " + q.a.toString() + " " + q.b.toString() + " " + q.c.toString() + " " + q.d.toString());
		var mx = S.m_step(7, new Mixed(3, I32x4.make(1, -2, 3, -4), 0.25), new Wrap(F32x4.make(2, 0, 0, 8)));
		Sys.println("mixed: " + mx.k + " " + mx.v.toString() + " " + mx.d);
		Sys.println("far: " + S.m_far(1, 2, 3, 4, 5, 6, 7, new Mixed(9, I32x4.make(1, 2, 3, 4), 0.5)));
		Sys.println("struct callbacks: " + VB.s_cb(Callback.addr(backWrap), Callback.addr(backQuad)));
		global();
		Sys.println("global: " + [for (k in 0...12) globalWord(k)].join(" "));
	}
}
