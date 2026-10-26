import hxmc.unsafe.*;

// C structs by value against each ABI's rules (hxmc/src/hxmc/CAbi.hx):
// System V's eightbyte classes (SSE, INTEGER, mixed, MEMORY), Win64's
// registers and copies, AAPCS64's aggregates of floats; arguments and
// results of each shape, register files that run out, callbacks C calls with
// them (FfiAbi.c, built by the corpus harness with zig).
@:hxmc.struct @:publicFields class F2 {
	var x:Float32;
	var y:Float32;
}

@:hxmc.struct @:publicFields class D4 {
	var a:Float;
	var b:Float;
	var c:Float;
	var d:Float;
}

@:hxmc.struct @:publicFields class IF {
	var i:Int;
	var f:Float32;
}

@:hxmc.struct @:publicFields class C3 {
	var a:UInt8;
	var b:UInt8;
	var c:UInt8;
}

@:hxmc.struct @:publicFields class DL {
	var d:Float;
	var l:Int64;
}

@:hxmc.struct @:publicFields class LD {
	var l:Int64;
	var d:Float;
}

@:hxmc.struct @:publicFields class I3 {
	var a:Int;
	var b:Int;
	var c:Int;
}

@:hxmc.struct @:publicFields class F3 {
	var x:Float32;
	var y:Float32;
	var z:Float32;
}

@:hxmc.struct @:publicFields class DF {
	var d:Float;
	var f:Float32;
}

@:hxmc.struct @:publicFields class SD {
	var s:Int16;
	var d:Float;
}

@:hxmc.struct @:publicFields class L3 {
	var a:Int64;
	var b:Int64;
	var c:Int64;
}

@:hxmc.struct @:publicFields class B40 {
	var a:Float;
	var b:Int64;
	var c:Int;
	var d:Float;
	var e:UInt16;
}

@:hxmc.struct @:publicFields class S6 {
	var a:Int16;
	var b:Int16;
	var c:Int16;
}

@:hxmc.c @:hxmc.fast extern class A {
	static function a_f2(x:Float32, y:Float32):F2;
	static function a_f2_sum(v:F2):Float;
	static function a_f2_twice(v:F2):F2;
	static function a_d4(a:Float, b:Float, c:Float, d:Float):D4;
	static function a_d4_sum(v:D4):Float;
	static function a_d4_twice(v:D4):D4;
	static function a_if(i:Int, f:Float32):IF;
	static function a_if_sum(v:IF):Float;
	static function a_if_twice(v:IF):IF;
	static function a_c3(a:Int, b:Int, c:Int):C3;
	static function a_c3_sum(v:C3):Int;
	static function a_c3_twice(v:C3):C3;
	static function a_dl(d:Float, l:Int64):DL;
	static function a_dl_sum(v:DL):Float;
	static function a_dl_twice(v:DL):DL;
	static function a_ld(l:Int64, d:Float):LD;
	static function a_ld_sum(v:LD):Float;
	static function a_ld_twice(v:LD):LD;
	static function a_i3(a:Int, b:Int, c:Int):I3;
	static function a_i3_sum(v:I3):Int64;
	static function a_i3_twice(v:I3):I3;
	static function a_f3(x:Float32, y:Float32, z:Float32):F3;
	static function a_f3_sum(v:F3):Float;
	static function a_f3_twice(v:F3):F3;
	static function a_df(d:Float, f:Float32):DF;
	static function a_df_sum(v:DF):Float;
	static function a_df_twice(v:DF):DF;
	static function a_sd(s:Int, d:Float):SD;
	static function a_sd_sum(v:SD):Float;
	static function a_sd_twice(v:SD):SD;
	static function a_l3(a:Int64, b:Int64, c:Int64):L3;
	static function a_l3_sum(v:L3):Int64;
	static function a_l3_twice(v:L3):L3;
	static function a_b40(a:Float, b:Int64, c:Int, d:Float, e:Int):B40;
	static function a_b40_sum(v:B40):Float;
	static function a_b40_twice(v:B40):B40;
	static function a_s6(a:Int, b:Int, c:Int):S6;
	static function a_s6_sum(v:S6):Int;
	static function a_s6_twice(v:S6):S6;
	static function a_gprs(a:Int, b:Int, c:Int, d:Int, e:Int, x:LD, f:Float, y:DL, g:Int):Float;
	static function a_xmms(d0:Float, d1:Float, d2:Float, d3:Float, d4:Float, d5:Float, d6:Float, d7:Float, v:F2, w:DF, z:Float, k:Int):Float;
	static function a_mixed(a:D4, b:B40, c:C3, k:Int, f:F3, l:L3, s:S6):Float;
	static function a_sret(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, x:Float, b40:B40):B40;
	static function a_fnptr():Ptr;
	@:hxmc.indirect static function dlTwice(fn:Ptr, v:DL):DL;
	// (a no-GC callback: called from a fast call)
	static function a_cb_f3(f:Ptr):Float;
}

// (calls in a safe region: GC callbacks leave it on entry)
@:hxmc.c extern class CB {
	static function a_cb_f2(f:Ptr):Float;
	static function a_cb_d4(f:Ptr):Float;
	static function a_cb_if(f:Ptr):Float;
	static function a_cb_c3(f:Ptr):Int;
	static function a_cb_dl(f:Ptr):Float;
	static function a_cb_df(f:Ptr):Float;
	static function a_cb_b40(f:Ptr):Float;
	static function a_cb_s6(f:Ptr):Int;
	static function a_cb_l3(f:Ptr):Int64;
	static function a_cb_spill(f:Ptr):Float;
}

// called back by C (FfiAbi.c, a_cb_*): structs received and returned by the ABI's rules
@:publicFields class Back {
	@:hxmc.callback static function f2(v:F2, k:Float):F2 {
		var r = v;
		r.x = (v.x : Float) * k;
		r.y = (v.y : Float) + k;
		return r;
	}

	@:hxmc.callback static function d4(v:D4):D4 {
		var r = v;
		r.a = v.d;
		r.d = v.a;
		return r;
	}

	@:hxmc.callback static function iff(k:Int, v:IF):IF {
		var r = v;
		r.i += k;
		r.f = (v.f : Float) * 4;
		return r;
	}

	@:hxmc.callback static function c3(v:C3):C3 {
		var r = v;
		r.a = v.c;
		r.c = v.a;
		return r;
	}

	@:hxmc.callback static function dl(v:DL, w:LD):DL {
		var r = v;
		r.d += w.d;
		r.l = r.l * w.l;
		return r;
	}

	// (@:hxmc.unsafe: called in any state)
	@:hxmc.callback @:hxmc.unsafe static function f3(a:F3, b:F3):F3 {
		var r = a;
		r.x = (a.x : Float) + (b.x : Float);
		r.y = (a.y : Float) + (b.y : Float);
		r.z = (a.z : Float) + (b.z : Float);
		return r;
	}

	@:hxmc.callback static function df(v:DF):DF {
		var junk = [for (i in 0...1000) "x" + i];
		var r = v;
		r.d *= junk.length;
		return r;
	}

	@:hxmc.callback static function b40(v:B40, k:Float):B40 {
		var r = v;
		r.a *= k;
		r.e += 1;
		return r;
	}

	@:hxmc.callback static function s6(v:S6):S6 {
		var r = v;
		r.b = -r.b;
		return r;
	}

	@:hxmc.callback static function l3(a:L3, b:L3):L3 {
		var r = a;
		r.a += b.a;
		r.b += b.b;
		r.c += b.c;
		return r;
	}

	@:hxmc.callback static function spill(a:Int, b:Int, c:Int, d:Int, e:Int, x:LD, d0:Float, d1:Float, d2:Float, d3:Float, d4:Float, d5:Float, d6:Float, w:DF, v:F2, y:DL, z:I3):Float {
		return a + b + c + d + e + 10 * haxe.Int64.toInt(x.l) + 100 * x.d + d0 + d1 + d2 + d3 + d4 + d5 + d6 + 1000 * w.d + 10000 * (w.f : Float) + 100000 * (v.x : Float)
			+ 1000000 * (v.y : Float) + 1e7 * y.d + 1e8 * haxe.Int64.toInt(y.l) + 1e9 * (z.a + z.b + z.c);
	}
}

// (calls in a safe region: the result's registers outlive rt_blocking_leave)
@:hxmc.c extern class Slow {
	@:native("a_dl_slow") static function dlTwice(v:DL):DL;
	@:native("a_b40_slow") static function b40Twice(v:B40):B40;
}

class FfiAbi {
	static function i64(v:Int64):String
		return haxe.Int64.toStr(v);

	static function main() {
		var f2 = A.a_f2(1.5, -2);
		var f2t = A.a_f2_twice(f2);
		trace("F2", f2.x, f2.y, A.a_f2_sum(f2), f2t.x, f2t.y);
		var d4 = A.a_d4(1, 2, 3, 4);
		var d4t = A.a_d4_twice(d4);
		trace("D4", A.a_d4_sum(d4), d4t.a, d4t.b, d4t.c, d4t.d, A.a_d4_sum(d4t));
		var fi = A.a_if(-7, 0.25);
		var fit = A.a_if_twice(fi);
		trace("IF", fi.i, fi.f, A.a_if_sum(fi), fit.i, fit.f);
		var c3 = A.a_c3(1, 2, 250);
		var c3t = A.a_c3_twice(c3);
		trace("C3", c3.a, c3.b, c3.c, A.a_c3_sum(c3), c3t.a, c3t.b, c3t.c);
		var dl = A.a_dl(0.5, 1 << 40);
		var dlt = A.a_dl_twice(dl);
		trace("DL", dl.d, i64(dl.l), A.a_dl_sum(dl), dlt.d, i64(dlt.l));
		var ld = A.a_ld(-3, 2.25);
		var ldt = A.a_ld_twice(ld);
		trace("LD", i64(ld.l), ld.d, A.a_ld_sum(ld), i64(ldt.l), ldt.d);
		var i3 = A.a_i3(7, -8, 9);
		var i3t = A.a_i3_twice(i3);
		trace("I3", i3.a, i3.b, i3.c, i64(A.a_i3_sum(i3)), i3t.a, i3t.b, i3t.c);
		var f3 = A.a_f3(0.5, 1.5, -2.5);
		var f3t = A.a_f3_twice(f3);
		trace("F3", f3.x, f3.y, f3.z, A.a_f3_sum(f3), f3t.x, f3t.y, f3t.z);
		var df = A.a_df(1.25, -0.5);
		var dft = A.a_df_twice(df);
		trace("DF", df.d, df.f, A.a_df_sum(df), dft.d, dft.f);
		var sd = A.a_sd(-300, 0.125);
		var sdt = A.a_sd_twice(sd);
		trace("SD", sd.s, sd.d, A.a_sd_sum(sd), sdt.s, sdt.d);
		var l3 = A.a_l3(1, 2, 3);
		var l3t = A.a_l3_twice(l3);
		trace("L3", i64(A.a_l3_sum(l3)), i64(l3t.a), i64(l3t.b), i64(l3t.c));
		var b40 = A.a_b40(0.5, 3, -4, 1.5, 65000);
		var b40t = A.a_b40_twice(b40);
		trace("B40", A.a_b40_sum(b40), b40t.a, i64(b40t.b), b40t.c, b40t.d, b40t.e);
		var s6 = A.a_s6(1, -2, 3);
		var s6t = A.a_s6_twice(s6);
		trace("S6", s6.a, s6.b, s6.c, A.a_s6_sum(s6), s6t.a, s6t.b, s6t.c);
		// arguments from memory (Ptr.value), registers running out
		Arena.scoped(ar -> {
			var pld = ar.make(LD);
			pld.value.l = 2;
			pld.value.d = 3;
			var pdl = ar.make(DL);
			pdl.value.d = 4;
			pdl.value.l = 5;
			trace("gprs", A.a_gprs(1, 1, 1, 1, 1, pld.value, 6, pdl.value, 7));
			var pf2 = ar.make(F2);
			pf2.value.x = 1;
			pf2.value.y = 2;
			var pdf = ar.make(DF);
			pdf.value.d = 3;
			pdf.value.f = 4;
			trace("xmms", A.a_xmms(1, 1, 1, 1, 1, 1, 1, 1, pf2.value, pdf.value, 5, 6));
			trace("mixed", A.a_mixed(d4, b40, c3, 9, f3, l3, s6));
			var r = A.a_sret(1, 2, 3, 4, 5, 6, 0.25, b40);
			trace("sret", r.a, i64(r.b), r.c, r.d, r.e);
			var ind = A.dlTwice(A.a_fnptr(), pdl.value);
			trace("indirect", ind.d, i64(ind.l));
			var s1 = Slow.dlTwice(dl);
			var s2 = Slow.b40Twice(b40);
			trace("slow", s1.d, i64(s1.l), s2.a, s2.e);
		});
		trace("callbacks", CB.a_cb_f2(Callback.addr(Back.f2)), CB.a_cb_d4(Callback.addr(Back.d4)), CB.a_cb_if(Callback.addr(Back.iff)), CB.a_cb_c3(Callback.addr(Back.c3)),
			CB.a_cb_dl(Callback.addr(Back.dl)), A.a_cb_f3(Callback.addr(Back.f3)));
		trace("callbacks", CB.a_cb_df(Callback.addr(Back.df)), CB.a_cb_b40(Callback.addr(Back.b40)), CB.a_cb_s6(Callback.addr(Back.s6)), i64(CB.a_cb_l3(Callback.addr(Back.l3))),
			CB.a_cb_spill(Callback.addr(Back.spill)));
		// a result in a loop: one slot per call
		var sum = 0.0;
		for (i in 0...4)
			sum += A.a_df_twice(A.a_df(i, i)).f;
		trace("loop", sum);
	}
}
