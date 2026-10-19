package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Boxes, array element access and growth, and Int conversion (once rt.c's
// and WebAssembly's wasm/Boxes.hx): references kept across allocations are
// ordinary locals here (the compiler roots them), raw addresses are taken
// again after each allocation. Small Int boxes and the two Bool boxes are
// static (outside the heap: the collector leaves them alone).
@:keep
class Boxes {
	static inline var SMALL_MIN = -128;
	static inline var SMALL_MAX = 1023;
	static inline var T_ADATA_RAW = 7;
	static inline var T_ADATA_P = 6;
	@:hxmc.bss(18432) static var smallInts:Ptr; // 16 bytes each (SMALL_MAX - SMALL_MIN + 1)
	@:hxmc.bss(32) static var boolBoxes:Ptr;

	static inline function mkhdr(nslots:Int, kind:Int, tindex:Int):I64
		return ((tindex : I64) << 32) | ((((kind << 28) | nslots) : I64) & 0xFFFFFFFF);

	// at startup (rt_init; WebAssembly's Gc.init)
	@:hxmc.host("hx_boxes_init") @:hxmc.noGc public static function init() {
		var n = SMALL_MAX - SMALL_MIN + 1;
		for (i in 0...n) {
			Mem.setI64(smallInts, 16 * i, mkhdr(1, K_OBJ, T_BOXINT));
			Mem.setI32(smallInts, 16 * i + 8, i + SMALL_MIN);
		}
		for (i in 0...2) {
			Mem.setI64(boolBoxes, 16 * i, mkhdr(1, K_OBJ, T_BOXBOOL));
			Mem.setI32(boolBoxes, 16 * i + 8, i);
		}
	}

	@:hxmc.export("hx_box_int") static function boxInt(v:Int):Dynamic {
		if (v >= SMALL_MIN && v <= SMALL_MAX) return Mem.obj(smallInts.add(16 * (v - SMALL_MIN) + 8));
		var b = Mem.allocRaw(1, T_BOXINT, K_OBJ);
		Mem.setI64(Mem.addr(b), 0, 0);
		Mem.setI32(Mem.addr(b), 0, v);
		return b;
	}

	@:hxmc.export("hx_box_float") static function boxFloat(v:Float):Dynamic {
		var b = Mem.allocRaw(1, T_BOXFLOAT, K_OBJ);
		Mem.setF64(Mem.addr(b), 0, v);
		return b;
	}

	@:hxmc.export("hx_box_i64") static function boxI64(v:I64):Dynamic {
		var b = Mem.allocRaw(1, T_BOXI64, K_OBJ);
		Mem.setI64(Mem.addr(b), 0, v);
		return b;
	}

	@:hxmc.export("hx_box_bool") @:hxmc.noGc static function boxBool(v:Int):Dynamic
		return Mem.obj(boolBoxes.add(v != 0 ? 24 : 8));

	@:hxmc.noGc static function f2l(f:Float):I64 {
		if (f != f) return 0;
		if (f >= 9223372036854775808.0) return ((1 : I64) << 63) - 1;
		if (f < -9223372036854775808.0) return (1 : I64) << 63;
		var l:I64 = cast f;
		return l;
	}

	// Std.int / Int casts: truncation in range; NaN gives 0, wider values wrap
	@:hxmc.noGc static inline function f2i(f:Float):Int
		return f > -2147483649.0 && f < 2147483648.0 ? (cast f : Int) : f2iSlow(f);

	@:hxmc.export("hx_f2i_slow") @:hxmc.noGc static function f2iSlow(f:Float):Int {
		if (f != f) return 0;
		if (f >= 2147483648.0 || f <= -2147483649.0) {
			var l:I64 = cast M.fmod(f, 4294967296.0);
			return l.toInt();
		}
		return cast f;
	}

	@:hxmc.export("hx_unbox_int") @:hxmc.noGc static function unboxInt(v:Dynamic):Int {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: f2i(Mem.getF64(p, 0));
			case T_BOXI64: Mem.getI64(p, 0).toInt();
			case _: 0;
		}
	}

	@:hxmc.export("hx_unbox_float") @:hxmc.noGc static function unboxFloat(v:Dynamic):Float {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: Mem.getF64(p, 0);
			case T_BOXI64:
				var f:Float = cast Mem.getI64(p, 0);
				f;
			case _: 0;
		}
	}

	@:hxmc.export("hx_unbox_i64") @:hxmc.noGc static function unboxI64(v:Dynamic):I64 {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: f2l(Mem.getF64(p, 0));
			case T_BOXI64: Mem.getI64(p, 0);
			case _: 0;
		}
	}

	@:hxmc.export("hx_unbox_bool") @:hxmc.noGc static function unboxBool(v:Dynamic):Int {
		var p = Mem.addr(v);
		if (p.isNull()) return 0;
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0) != 0 ? 1 : 0;
			case T_BOXFLOAT: Mem.getF64(p, 0) != 0 ? 1 : 0;
			case T_BOXI64: Mem.getI64(p, 0) == 0 ? 0 : 1;
			case _: 1;
		}
	}

	// ---- arrays (slot 0 the length and the element kind, slot 1 the data)

	static inline function arrLen(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 0);

	static inline function arrKind(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 4);

	static inline function arrData(a:Dynamic):Ptr
		return Mem.getPtr(Mem.addr(a), 8);

	static inline function arrCap(a:Dynamic):Int {
		var d = arrData(a);
		return d.isNull() ? 0 : (Mem.getI32(d, -8) & 0x0FFFFFFF) << (ak4(arrKind(a)) ? 1 : 0);
	}

	static function dataAlloc(kind:Int, cap:Int):Dynamic {
		if (cap < 1) cap = 1;
		return switch kind {
			case AK_I32 | AK_BOOL: Mem.alloc((cap + 1) >> 1, T_ADATA_RAW, K_RAW);
			case AK_F64 | AK_I64: Mem.alloc(cap, T_ADATA_RAW, K_RAW);
			case _: Mem.alloc(cap, T_ADATA_P, K_PARR);
		}
	}

	@:hxmc.export("hx_arr_new_n") static function arrNewN(kind:Int, len:Int):Dynamic {
		var ds = ak4(kind) ? (len + 1) >> 1 : len;
		if (ds < 1) ds = 1;
		if (ds <= 64) {
			// small: the array and its data in one allocation (one bump, no
			// root), split by writing the second header; both are young
			var a = Mem.alloc(3 + ds, T_ARRAY, K_OBJ);
			var p = Mem.addr(a);
			Mem.setI64(p, -8, mkhdr(2, K_OBJ, T_ARRAY));
			Mem.setI32(p, 0, len);
			Mem.setI32(p, 4, kind);
			Mem.setPtr(p, 8, p.add(24));
			Mem.setI64(p, 16, kind == AK_PTR ? mkhdr(ds, K_PARR, T_ADATA_P) : mkhdr(ds, K_RAW, T_ADATA_RAW));
			return a;
		}
		var d = dataAlloc(kind, len);
		var a = Mem.alloc(2, T_ARRAY, K_OBJ);
		Mem.setI32(Mem.addr(a), 0, len);
		Mem.setI32(Mem.addr(a), 4, kind);
		Mem.setRefBarrier(a, 8, d);
		return a;
	}

	@:hxmc.host("hx_arr_grow") static function arrGrow(slot:Ptr, need:Int):Void {
		var a:Dynamic = Mem.getRef(slot, 0);
		var cap = arrCap(a);
		if (need <= cap) return;
		var ncap = cap * 2;
		if (ncap < 2) ncap = 2;
		if (ncap < need) ncap = need;
		var kind = arrKind(a);
		var d0 = arrData(a);
		var nd = dataAlloc(kind, ncap);
		// (another thread may have changed the array at the allocation: a
		// replaced data or kind retries)
		a = Mem.getRef(slot, 0);
		if (arrData(a) != d0 || arrKind(a) != kind) {
			arrGrow(slot, need);
			return;
		}
		var len = arrLen(a);
		var d = arrData(a);
		if (!d.isNull()) {
			var es = ak4(kind) ? 4 : 8;
			LibC.memcpy(Mem.addr(nd), d, es * len);
			if (kind == AK_PTR && !inYoungObj(nd)) Gc_barrierRange(nd, len);
		}
		Mem.setRefBarrier(a, 8, nd);
	}

	@:hxmc.noGc static function inYoungObj(o:Dynamic):Bool {
		var p = Mem.addr(o);
		return !p.ult(Mem.getPtr(Mem.sym("rt_young_start"), 0)) && p.ult(Mem.getPtr(Mem.sym("rt_young_end"), 0));
	}

	@:hxmc.noGc static function Gc_barrierRange(o:Dynamic, n:Int)
		hxmc.rt.C.Leaf.rt_barrier_range(o, Mem.addr(o), n);

	@:hxmc.host("hx_arr_to_ptr") static function arrToPtr(slot:Ptr):Void {
		var a:Dynamic = Mem.getRef(slot, 0);
		if (arrKind(a) == AK_PTR) return;
		var len = arrLen(a);
		var nd = dataAlloc(AK_PTR, len);
		for (i in 0...len) {
			a = Mem.getRef(slot, 0);
			var k = arrKind(a);
			var v:Dynamic = k == AK_I32 ? boxInt(Mem.getI32At(arrData(a), 0, i)) : k == AK_BOOL ? boxBool(Mem.getI32At(arrData(a), 0, i)) : k == AK_I64 ? boxI64(Mem.getI64At(arrData(a), 0, i)) : boxFloat(Mem.getF64At(arrData(a), 0, i));
			Mem.setRefBarrier(nd, 8 * i, v);
		}
		a = Mem.getRef(slot, 0);
		Mem.setI32(Mem.addr(a), 4, AK_PTR);
		Mem.setRefBarrier(a, 8, nd);
	}

	@:hxmc.export("hx_aget_i_slow") @:hxmc.noGc static function agetI(a:Dynamic, i:Int):Int {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return 0;
		var d = arrData(a);
		return switch arrKind(a) {
			case AK_I32 | AK_BOOL: Mem.getI32At(d, 0, i);
			case AK_F64: f2i(Mem.getF64At(d, 0, i));
			case AK_I64: Mem.getI64At(d, 0, i).toInt();
			case _: unboxInt(Mem.getRefAt(d, 0, i));
		}
	}

	@:hxmc.export("hx_aget_l_slow") @:hxmc.noGc static function agetL(a:Dynamic, i:Int):I64 {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return 0;
		var d = arrData(a);
		return switch arrKind(a) {
			case AK_I32 | AK_BOOL: Mem.getI32At(d, 0, i);
			case AK_F64: f2l(Mem.getF64At(d, 0, i));
			case AK_I64: Mem.getI64At(d, 0, i);
			case _: unboxI64(Mem.getRefAt(d, 0, i));
		}
	}

	@:hxmc.export("hx_aget_f_slow") @:hxmc.noGc static function agetF(a:Dynamic, i:Int):Float {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return 0;
		var d = arrData(a);
		return switch arrKind(a) {
			case AK_I32 | AK_BOOL: Mem.getI32At(d, 0, i);
			case AK_F64: Mem.getF64At(d, 0, i);
			case AK_I64:
				var f:Float = cast Mem.getI64At(d, 0, i);
				f;
			case _: unboxFloat(Mem.getRefAt(d, 0, i));
		}
	}

	@:hxmc.export("hx_aget_p_slow") static function agetP(a:Dynamic, i:Int):Dynamic {
		if (Mem.addr(a).isNull() || !Mem.ult(i, arrLen(a))) return null;
		return switch arrKind(a) {
			case AK_I32: boxInt(Mem.getI32At(arrData(a), 0, i));
			case AK_BOOL: boxBool(Mem.getI32At(arrData(a), 0, i));
			case AK_F64: boxFloat(Mem.getF64At(arrData(a), 0, i));
			case AK_I64: boxI64(Mem.getI64At(arrData(a), 0, i));
			case _: Mem.getRefAt(arrData(a), 0, i);
		}
	}

	// store v (of kind vk; AK_PTR: v is the address of a rooted slot) at i < length;
	// a value the array's kind cannot hold (a Bool in an Int array, an Int in a
	// Bool array) turns it into a reference array first
	static function storeConv(slot:Ptr, i:Int, vk:Int, v:I64):Void {
		var a:Dynamic = Mem.getRef(slot, 0);
		var ak = arrKind(a);
		if (ak == AK_PTR) {
			var p:Dynamic = switch vk {
				case AK_I32: boxInt(v.toInt());
				case AK_BOOL: boxBool(v.toInt());
				case AK_F64: boxFloat(haxe.io.FPHelper.i64ToDouble(v.toInt(), (v >> 32).toInt()));
				case AK_I64: boxI64(v);
				case _: Mem.getRef(new Ptr(v), 0);
			}
			a = Mem.getRef(slot, 0);
			Mem.setRefBarrier(Mem.obj(arrData(a)), 8 * i, p);
			return;
		}
		if (vk == AK_PTR) {
			var p:Dynamic = Mem.getRef(new Ptr(v), 0);
			var t = Mem.addr(p).isNull() ? (ak == AK_BOOL ? T_BOXBOOL : T_BOXINT) : tindex(p);
			var fits = switch ak {
				case AK_I32: t == T_BOXINT;
				case AK_BOOL: t == T_BOXBOOL;
				case AK_F64: t == T_BOXINT || t == T_BOXFLOAT;
				case _: t == T_BOXINT || t == T_BOXI64;
			}
			if (!fits) {
				arrToPtr(slot);
				storeConv(slot, i, vk, v);
				return;
			}
			var d = arrData(a);
			if (ak4(ak)) Mem.setI32At(d, 0, i, unboxInt(p)) else if (ak == AK_F64) Mem.setF64At(d, 0, i, unboxFloat(p)) else
				Mem.setI64At(d, 0, i, unboxI64(p));
			return;
		}
		if (vk != ak && !(vk == AK_I32 && (ak == AK_F64 || ak == AK_I64))) {
			arrToPtr(slot);
			storeConv(slot, i, vk, v);
			return;
		}
		var d = arrData(a);
		if (ak4(ak)) Mem.setI32At(d, 0, i, v.toInt()) else if (ak == AK_F64) {
			if (vk == AK_I32) Mem.setF64At(d, 0, i, v.toInt()) else Mem.setI64At(d, 0, i, v);
		} else
			Mem.setI64At(d, 0, i, vk == AK_I32 ? (v.toInt() : I64) : v);
	}

	@:hxmc.export("hx_aset_slow") static function asetSlow(slot:Ptr, i:Int, vk:Int, v:I64):Void {
		if (i < 0) return;
		var a:Dynamic = Mem.getRef(slot, 0);
		if (!Mem.ult(i, arrLen(a))) {
			arrGrow(slot, i + 1);
			a = Mem.getRef(slot, 0);
			if (!Mem.ult(i, arrLen(a))) Mem.setI32(Mem.addr(a), 0, i + 1);
		}
		storeConv(slot, i, vk, v);
	}

	// the push of a value of kind vk (AK_PTR: v is the address of a rooted
	// slot) that the inline path left: a full array, one without data yet, or
	// another kind. The usual case, a full one of the value's kind, grows here
	// in one go (twice the capacity, at least 2, as arrGrow) and stores
	// directly; the others, and an array changed at the allocation, take
	// pushConv
	@:hxmc.export("hx_apush_slow") static function apushSlow(slot:Ptr, vk:Int, v:I64):Int {
		var a:Dynamic = Mem.getRef(slot, 0);
		var k = arrKind(a);
		if (k != vk) return pushConv(slot, vk, v);
		var n = arrLen(a);
		var d = arrData(a);
		var cap = arrCap(a);
		if (n < cap) {
			setLen(a, n + 1);
			storeKind(d, n, k, v);
			return n;
		}
		var ncap = cap * 2;
		if (ncap < 2) ncap = 2;
		if (ncap < n + 1) ncap = n + 1;
		var nd:Dynamic = k == AK_PTR ? Mem.alloc(ncap, T_ADATA_P, K_PARR) : Mem.alloc(ak4(k) ? (ncap + 1) >> 1 : ncap, T_ADATA_RAW, K_RAW);
		a = Mem.getRef(slot, 0);
		if (arrData(a) != d || arrKind(a) != k || arrLen(a) != n) return pushConv(slot, vk, v);
		if (n > 0) {
			var bytes = n << (ak4(k) ? 2 : 3);
			LibC.memcpy(Mem.addr(nd), d, bytes);
			if (k == AK_PTR && !inYoungObj(nd)) Gc_barrierRange(nd, n);
		}
		Mem.setRefBarrier(a, 8, nd);
		setLen(a, n + 1);
		storeKind(Mem.addr(nd), n, k, v);
		return n;
	}

	static inline function setLen(a:Dynamic, n:Int)
		Mem.setI32(Mem.addr(a), 0, n);

	// v (of the array's kind k) stored at i in the data d
	static inline function storeKind(d:Ptr, i:Int, k:Int, v:I64) {
		if (k == AK_PTR) Mem.setRefBarrier(Mem.obj(d), 8 * i, Mem.getRef(new Ptr(v), 0)) else if (ak4(k)) Mem.setI32At(d, 0, i, v.toInt()) else
			Mem.setI64At(d, 0, i, v);
	}

	static function pushConv(slot:Ptr, vk:Int, v:I64):Int {
		var a:Dynamic = Mem.getRef(slot, 0);
		var n = arrLen(a);
		while (n >= arrCap(a)) {
			arrGrow(slot, n + 1);
			a = Mem.getRef(slot, 0);
			n = arrLen(a);
		}
		Mem.setI32(Mem.addr(a), 0, n + 1);
		storeConv(slot, n, vk, v);
		return n;
	}
}

@:hxmc.c @:hxmc.fast private extern class M {
	static function fmod(x:Float, y:Float):Float;
}
