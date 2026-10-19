package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// hxmc.rt.Repr in linear memory, over Mem (rt.h's layouts; addresses of
// heap objects valid until the next GC point).
class MemRepr {
	static inline var T_STRING = 1;
	static inline var T_ADATA_RAW = 7;
	static inline var T_STRINGBUF = 10;
	static inline var K_OBJ = 0;
	static inline var K_RAW = 2;
	static inline var T_BYTES = 8;
	static inline var T_BYTESBUFFER = 9;
	static inline var T_NATIVE = 16;

	public static inline function isNull(o:Dynamic):Bool
		return Mem.addr(o).isNull();

	// the same object (or both null)
	public static inline function same(a:Dynamic, b:Dynamic):Bool
		return Mem.addr(a) == Mem.addr(b);

	// a < b as unsigned (a in [0, b) for b >= 0)
	public static inline function ult(a:Int, b:Int):Bool
		return Mem.ult(a, b);

	public static inline function stdString(v:Dynamic):String
		return Dyn.stdString(v);

	public static inline function dynEq(a:Dynamic, b:Dynamic):Bool
		return Dyn.dynEq(a, b);

	// a boxed Float, a boxed Bool, their values (Bool's 0 or 1)
	public static inline function isBoxedFloat(x:Dynamic):Bool
		return Types.tindex(x) == Types.T_BOXFLOAT;

	public static inline function isBoxedBool(x:Dynamic):Bool
		return Types.tindex(x) == Types.T_BOXBOOL;

	public static inline function unboxedFloat(x:Dynamic):Float
		return Mem.getF64(Mem.addr(x), 0);

	public static inline function unboxedBool(x:Dynamic):Int
		return Mem.getI32(Mem.addr(x), 0);

	// throws msg
	public static inline function fail(msg:String)
		Rt.rt_throw(msg);

	// ---- strings: K_RAW, int32 length, int32 hash (0: not computed yet), the
	// UTF-16 units from offset 8

	public static inline function len(s:String):Int
		return Mem.getI32(Mem.addr(s), 0);

	public static inline function unit(s:String, i:Int):Int
		return Mem.getU16At(Mem.addr(s), 8, i);

	public static inline function chars(s:String):MemChars
		return Mem.addr(s).add(8);

	// length set, hash 0, the units not written
	public static inline function make(n:Int):String {
		var s:String = Mem.allocRaw((2 * n + 15) >> 3, T_STRING, K_RAW);
		Mem.setI64(Mem.addr(s), 0, (n : I64));
		return s;
	}

	public static inline function storedHash(s:String):Int
		return Mem.getI32(Mem.addr(s), 4);

	public static inline function storeHash(s:String, h:Int)
		Mem.setI32(Mem.addr(s), 4, h);

	// unit i (a constant) of s set
	public static inline function setUnit(s:String, i:Int, v:Int)
		Mem.setI16(Mem.addr(s), 8 + 2 * i, v);

	// dst[0, n) = src[0, n) (not overlapping); copyFrom: from src[si, si + n);
	// copyTo: to dst[di, di + n)
	public static inline function copy(dst:MemChars, src:MemChars, n:Int)
		LibC.memcpy(dst, src, (2 * n : I64));

	public static inline function copyFrom(dst:MemChars, src:MemChars, si:Int, n:Int)
		LibC.memcpy(dst, src.at(si), (2 * n : I64));

	public static inline function copyTo(dst:MemChars, di:Int, src:MemChars, n:Int)
		LibC.memcpy(dst.at(di), src, (2 * n : I64));

	// c[i, i + m) == d[0, m)
	public static inline function eqUnits(c:MemChars, i:Int, d:MemChars, m:Int):Bool
		return MemOps.compare(c.at(i), d, (2 * m : I64)) == 0;

	// the same, m >= 1: the first unit compared first
	@:hxmc.noGc public static inline function matchAt(c:MemChars, d:MemChars, i:Int, m:Int):Bool
		return Mem.getU16At(c, 0, i) == Mem.getU16(d, 0) && (m == 1 || MemOps.compare((c : Ptr).add(2 * i + 2), (d : Ptr).add(2), (2 * (m - 1) : I64)) == 0);

	// ---- StringBuf (T_STRINGBUF): slot 0 the length, slot 1 a K_RAW block of
	// units (its capacity from its header: 4 units per slot)

	public static inline function sbNew():Dynamic {
		var b = Mem.alloc(2, T_STRINGBUF, K_OBJ);
		var d = Mem.allocRaw(8, T_ADATA_RAW, K_RAW);
		Mem.setRefBarrier(b, 8, d);
		return b;
	}

	public static inline function sbLen(b:Dynamic):Int
		return Mem.getI32(Mem.addr(b), 0);

	public static inline function sbSetLen(b:Dynamic, n:Int)
		Mem.setI32(Mem.addr(b), 0, n);

	static inline function sbData(b:Dynamic):Dynamic
		return Mem.getRef(Mem.addr(b), 8);

	public static inline function sbChars(b:Dynamic):MemChars
		return Mem.addr(sbData(b));

	public static inline function sbCapacity(b:Dynamic):Int
		return (Mem.getI32(Mem.addr(sbData(b)), -8) & 0x0FFFFFFF) << 2;

	// new storage of `cap` units, the first n copied
	public static inline function sbGrow(b:Dynamic, cap:Int, n:Int) {
		var nd = Mem.allocRaw((cap + 3) >> 2, T_ADATA_RAW, K_RAW);
		LibC.memcpy(Mem.addr(nd), Mem.addr(sbData(b)), (2 * n : I64));
		Mem.setRefBarrier(b, 8, nd);
	}

	// ---- arrays (rt.h): slot 0 the length and the element kind, slot 1 the
	// data, null while empty; Int and Bool elements take 4 bytes, others 8

	public static inline var AK_PTR = Types.AK_PTR;
	public static inline var AK_I32 = Types.AK_I32;
	public static inline var AK_F64 = Types.AK_F64;
	public static inline var AK_I64 = Types.AK_I64;
	public static inline var AK_BOOL = Types.AK_BOOL;

	public static inline function arrLen(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 0);

	public static inline function arrSetLen(a:Dynamic, n:Int)
		Mem.setI32(Mem.addr(a), 0, n);

	public static inline function arrKind(a:Dynamic):Int
		return Mem.getI32(Mem.addr(a), 4);

	public static inline function arrData(a:Dynamic):Ptr
		return Mem.getPtr(Mem.addr(a), 8);

	public static inline function elemSize(a:Dynamic):Int
		return Types.ak4(arrKind(a)) ? 4 : 8;

	public static inline function elems(a:Dynamic):MemElems
		return arrData(a);

	public static inline function arrMake(kind:Int, n:Int):Dynamic {
		if (n == 0) {
			// `[]`: the data is allocated by the first store
			var a = Mem.alloc(2, Types.T_ARRAY, K_OBJ);
			Mem.setI32(Mem.addr(a), 4, kind);
			return a;
		}
		return Rt.hx_arr_new_n(kind, n);
	}

	// the data of a fresh reference array was written without the barrier
	static inline function barrierAll(a:Dynamic, n:Int) {
		if (arrKind(a) == AK_PTR && n > 0) barrier(arrData(a), arrData(a), n);
	}

	// rt_barrier_range for n slots from `from` in the data d, unless d is young
	// (the usual case: fresh, or recently allocated, data)
	static inline function barrier(d:Ptr, from:Ptr, n:Int) {
		if (d.ult(Mem.getPtr(Mem.sym("rt_young_start"), 0)) || !d.ult(Mem.getPtr(Mem.sym("rt_young_end"), 0)))
			Leaf.rt_barrier_range(Mem.obj(d), from, n);
	}

	// r[0, n) = a[0, n) (r new)
	public static inline function arrCopy(r:Dynamic, a:Dynamic, n:Int) {
		if (n > 0) LibC.memcpy(arrData(r), arrData(a), (elemSize(a) * n : I64));
		barrierAll(r, n);
	}

	// r[0, na) = a[0, na), r[na, na + nb) = b[0, nb) (r new, a and b of its kind)
	public static inline function arrCopy2(r:Dynamic, a:Dynamic, na:Int, b:Dynamic, nb:Int) {
		if (na + nb > 0) {
			var es = elemSize(a);
			if (na > 0) LibC.memcpy(arrData(r), arrData(a), (es * na : I64));
			if (nb > 0) LibC.memcpy(arrData(r).add(es * na), arrData(b), (es * nb : I64));
			barrierAll(r, na + nb);
		}
	}

	// r[0, l) = a[pos, pos + l) (r new)
	public static inline function arrCopyFrom(r:Dynamic, a:Dynamic, pos:Int, l:Int) {
		if (l > 0) LibC.memcpy(arrData(r), arrData(a).add(elemSize(a) * pos), (elemSize(a) * l : I64));
		barrierAll(r, l);
	}

	// element i removed, the rest shifted down
	public static inline function arrRemoveAt(a:Dynamic, i:Int) {
		var n = arrLen(a), es = elemSize(a);
		var d = arrData(a);
		LibC.memmove(d.add(es * i), d.add(es * (i + 1)), (es * (n - i - 1) : I64));
		LibC.memset(d.add(es * (n - 1)), 0, es);
		if (arrKind(a) == AK_PTR && n - i - 1 > 0) barrier(d, d.add(8 * i), n - i - 1);
		arrSetLen(a, n - 1);
	}

	// the last of n elements removed and returned (taken, its slot cleared,
	// before the value is boxed: the array is not live across that
	// allocation, so needs no root)
	@:access(hxmc.rt.Boxes) public static inline function arrPop(a:Dynamic, n:Int):Dynamic {
		n--;
		var k = arrKind(a);
		var d = arrData(a);
		arrSetLen(a, n);
		if (k == AK_PTR) {
			var v = Mem.getRefAt(d, 0, n);
			Mem.setI64At(d, 0, n, 0);
			return v;
		}
		if (Types.ak4(k)) {
			var x = Mem.getI32At(d, 0, n);
			Mem.setI32At(d, 0, n, 0);
			return k == AK_BOOL ? Boxes.boxBool(x) : Boxes.boxInt(x);
		}
		if (k == AK_F64) {
			var x = Mem.getF64At(d, 0, n);
			Mem.setI64At(d, 0, n, 0);
			return Boxes.boxFloat(x);
		}
		var x = Mem.getI64At(d, 0, n);
		Mem.setI64At(d, 0, n, 0);
		return Boxes.boxI64(x);
	}

	// cut from m elements to n (what is cut cleared)
	public static inline function arrCut(a:Dynamic, n:Int, m:Int) {
		LibC.memset(arrData(a).add(elemSize(a) * n), 0, (elemSize(a) * (m - n) : I64));
		arrSetLen(a, n);
	}

	// element n (the last) moved to pos, [pos, n) one up
	public static inline function arrRotate(a:Dynamic, pos:Int, n:Int) {
		var es = elemSize(a);
		var d = arrData(a);
		var tmp = es == 4 ? (Mem.getI32(d, 4 * n) : I64) : Mem.getI64(d, 8 * n);
		LibC.memmove(d.add(es * (pos + 1)), d.add(es * pos), (es * (n - pos) : I64));
		if (es == 4) Mem.setI32(d, 4 * pos, tmp.toInt()) else Mem.setI64(d, 8 * pos, tmp);
		if (arrKind(a) == AK_PTR) barrier(d, d.add(8 * pos), n - pos + 1);
	}

	// the n >= 2 elements in reverse order
	public static inline function arrReverse(a:Dynamic, n:Int) {
		var d = arrData(a);
		var i = 0, j = n - 1;
		if (elemSize(a) == 4)
			while (i < j) {
				var t = Mem.getI32At(d, 0, i);
				Mem.setI32At(d, 0, i, Mem.getI32At(d, 0, j));
				Mem.setI32At(d, 0, j, t);
				i++;
				j--;
			}
		else
			while (i < j) {
				var t = Mem.getI64At(d, 0, i);
				Mem.setI64At(d, 0, i, Mem.getI64At(d, 0, j));
				Mem.setI64At(d, 0, j, t);
				i++;
				j--;
			}
		if (arrKind(a) == AK_PTR) barrier(d, d, n);
	}

	// a[pos, pos + l) moved to r (new), the rest of a's n elements down
	public static inline function arrSplice(a:Dynamic, r:Dynamic, pos:Int, l:Int, n:Int) {
		var es = elemSize(a);
		var d = arrData(a);
		if (l > 0) LibC.memcpy(arrData(r), d.add(es * pos), (es * l : I64));
		if (n > 0) {
			LibC.memmove(d.add(es * pos), d.add(es * (pos + l)), (es * (n - pos - l) : I64));
			LibC.memset(d.add(es * (n - l)), 0, (es * l : I64));
		}
		arrSetLen(a, n - l);
		if (arrKind(a) == AK_PTR) {
			barrierAll(r, l);
			if (n - pos - l > 0) barrier(d, d.add(8 * pos), n - pos - l);
		}
	}

	// ---- linear memory (C's)

	// the n bytes at p
	public static inline function octetsAt(p:Ptr, n:Int):MemOctets
		return p;

	// s as UTF-8 at p (3 * length + 1 bytes), NUL-terminated; the byte count
	public static inline function utf8To(s:String, p:Ptr):Int
		return Str.utf8Into(s, p);

	// ---- Bytes: K_RAW, int32 length, the bytes from offset 8

	public static inline function bytesLen(b:Dynamic):Int
		return Mem.getI32(Mem.addr(b), 0);

	public static inline function octets(b:Dynamic):MemOctets
		return Mem.addr(b).add(8);

	public static inline function bytesAllocUninit(n:Int):Dynamic {
		var b = Mem.allocRaw((n + 15) >> 3, T_BYTES, K_RAW);
		Mem.setI32(Mem.addr(b), 0, n);
		return b;
	}

	// dst[di, di + n) = src[si, si + n) (bytesMove: they may overlap)
	public static inline function bytesMove(dst:Dynamic, di:Int, src:Dynamic, si:Int, n:Int)
		LibC.memmove(octets(dst).at(di), octets(src).at(si), n);

	public static inline function bytesCopyAt(dst:Dynamic, di:Int, src:Dynamic, si:Int, n:Int)
		LibC.memcpy(octets(dst).at(di), octets(src).at(si), n);

	// dst[0, n) = src[si, si + n)
	public static inline function bytesCopyFrom(dst:Dynamic, src:Dynamic, si:Int, n:Int)
		LibC.memcpy(octets(dst), octets(src).at(si), n);

	// dst[0, n) = src[0, n)
	public static inline function copyOctets(dst:MemOctets, src:MemOctets, n:Int)
		LibC.memcpy(dst, src, n);

	public static inline function bytesFill(b:Dynamic, pos:Int, n:Int, v:Int)
		LibC.memset(octets(b).at(pos), v, n);

	// the difference of the first differing bytes of [0, n), else 0
	@:hxmc.noGc public static inline function compareOctets(a:MemOctets, b:MemOctets, n:Int):Int
		return MemOps.compare(a, b, n);

	// ---- BytesBuffer (T_BYTESBUFFER): slot 0 the length, slot 1 a Bytes

	public static inline function bbNew():Dynamic {
		var bb = Mem.alloc(2, T_BYTESBUFFER, K_OBJ);
		var d = @:privateAccess Bytes.alloc(64);
		Mem.setRefBarrier(bb, 8, d);
		return bb;
	}

	public static inline function bbLen(bb:Dynamic):Int
		return Mem.getI32(Mem.addr(bb), 0);

	public static inline function bbSetLen(bb:Dynamic, n:Int)
		Mem.setI32(Mem.addr(bb), 0, n);

	public static inline function bbData(bb:Dynamic):Dynamic
		return Mem.getRef(Mem.addr(bb), 8);

	public static inline function bbSetData(bb:Dynamic, d:Dynamic)
		Mem.setRefBarrier(bb, 8, d);

	// ---- Date: T_NATIVE K_RAW, the milliseconds since the epoch (a double);
	// the calendar's fields are struct tm's (Date)

	public static inline var F_SEC = 0;
	public static inline var F_MIN = 4;
	public static inline var F_HOUR = 8;
	public static inline var F_MDAY = 12;
	public static inline var F_MON = 16;
	public static inline var F_YEAR = 20;
	public static inline var F_WDAY = 24;
	static inline var F_ISDST = 32;
	// F_YEAR's value + YEAR_BASE: the year
	public static inline var YEAR_BASE = 1900;

	public static inline function dateOf(ms:Float):Dynamic {
		var d = Mem.allocRaw(1, T_NATIVE, K_RAW);
		Mem.setF64(Mem.addr(d), 0, ms);
		return d;
	}

	public static inline function dateMs(d:Dynamic):Float
		return Mem.getF64(Mem.addr(d), 0);

	// a local time's milliseconds
	public static inline function dateLocal(y:Int, m:Int, d:Int, h:Int, mi:Int, s:Int):Float {
		var tm = Mem.stack(64);
		LibC.memset(tm, 0, 64);
		Mem.setI32(tm, F_YEAR, y - 1900);
		Mem.setI32(tm, F_MON, m);
		Mem.setI32(tm, F_MDAY, d);
		Mem.setI32(tm, F_HOUR, h);
		Mem.setI32(tm, F_MIN, mi);
		Mem.setI32(tm, F_SEC, s);
		Mem.setI32(tm, F_ISDST, -1);
		var t:Float = cast @:privateAccess Date.mktime(tm);
		return t * 1000.0;
	}

	public static inline function dateNow():Float {
		var ts = Mem.stack(16);
		LibC.clock_gettime(0, ts); // CLOCK_REALTIME
		var sec:Float = cast Mem.getI64(ts, 0);
		var nsec:Float = Mem.getI32(ts, 8);
		return sec * 1000.0 + nsec / 1e6;
	}

	// a field of the date d (local or UTC)
	public static inline function dateField(d:Dynamic, utc:Bool, f:Int):Int {
		var tm = Mem.stack(64);
		@:privateAccess Date.breakDown(dateMs(d), utc, tm);
		return Mem.getI32(tm, f);
	}

	// the local fields of the date d
	public static inline function dateFields(d:Dynamic):MemTm {
		var tm = Mem.stack(64);
		@:privateAccess Date.breakDown(dateMs(d), false, tm);
		return tm;
	}

	// minutes from local time to UTC
	public static inline function timezoneOffset(d:Dynamic):Int {
		var l = Mem.stack(64), u = Mem.stack(64);
		@:privateAccess Date.breakDown(dateMs(d), false, l);
		@:privateAccess Date.breakDown(dateMs(d), true, u);
		return ((@:privateAccess Date.mktime(u) - @:privateAccess Date.mktime(l)) / 60).toInt();
	}

	// ---- bit patterns (through a frame area)

	public static inline function i32ToFloat(i:Int):Float {
		var p = Mem.stack(8);
		Mem.setI32(p, 0, i);
		return Mem.getF32(p, 0);
	}

	public static inline function floatToI32(v:Float):Int {
		var p = Mem.stack(8);
		Mem.setF32(p, 0, v);
		return Mem.getI32(p, 0);
	}

	public static inline function i64ToDouble(low:Int, high:Int):Float {
		var p = Mem.stack(8);
		Mem.setI32(p, 0, low);
		Mem.setI32(p, 4, high);
		return Mem.getF64(p, 0);
	}

	public static inline function doubleLow(v:Float):Int {
		var p = Mem.stack(8);
		Mem.setF64(p, 0, v);
		return Mem.getI32(p, 0);
	}

	public static inline function doubleHigh(v:Float):Int {
		var p = Mem.stack(8);
		Mem.setF64(p, 0, v);
		return Mem.getI32(p, 4);
	}
}

// a string's UTF-16 units: the address of the first
abstract MemChars(Ptr) from Ptr to Ptr {
	public inline function get(i:Int):Int
		return Mem.getU16At(this, 0, i);

	public inline function set(i:Int, v:Int)
		Mem.setU16At(this, 0, i, v);

	// the address of unit i
	public inline function at(i:Int):Ptr
		return this.add(2 * i);
}

// a broken-down time: a struct tm
abstract MemTm(Ptr) from Ptr to Ptr {
	public inline function get(f:Int):Int
		return Mem.getI32(this, f);
}

// an array's elements: the address of the first
abstract MemElems(Ptr) from Ptr to Ptr {
	public inline function getInt(i:Int):Int
		return Mem.getI32At(this, 0, i);

	public inline function getBool(i:Int):Int
		return Mem.getI32At(this, 0, i);

	public inline function getFloat(i:Int):Float
		return Mem.getF64At(this, 0, i);

	public inline function getI64(i:Int):I64
		return Mem.getI64At(this, 0, i);

	public inline function getRef(i:Int):Dynamic
		return Mem.getRefAt(this, 0, i);
}

// bytes: the address of the first
abstract MemOctets(Ptr) from Ptr to Ptr {
	public inline function get(i:Int):Int
		return Mem.getU8At(this, 0, i);

	public inline function set(i:Int, v:Int)
		Mem.setU8At(this, 0, i, v);

	// the address of byte i
	public inline function at(i:Int):Ptr
		return this.add(i);

	// little-endian at byte pos
	public inline function getU16(pos:Int):Int
		return Mem.getU16(this, pos);

	public inline function setU16(pos:Int, v:Int)
		Mem.setI16(this, pos, v);

	public inline function setI32(pos:Int, v:Int)
		Mem.setI32(this, pos, v);

	public inline function setF32(pos:Int, v:Float)
		Mem.setF32(this, pos, v);

	public inline function setF64(pos:Int, v:Float)
		Mem.setF64(this, pos, v);
}
