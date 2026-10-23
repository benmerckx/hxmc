package hxmc.rt.gc;

// hxmc.rt.Repr under -D hxmc.wasm-gc, over WasmGC objects (W): a String is
// an array of UTF-16 units, a StringBuf a GcStringBuf.
class GcRepr {
	public static inline function isNull(o:Dynamic):Bool
		return W.isNull(o);

	// the same reference (or both null)
	public static inline function same(a:Dynamic, b:Dynamic):Bool
		return W.same(a, b);

	// a < b as unsigned (a in [0, b) for b >= 0)
	public static inline function ult(a:Int, b:Int):Bool
		return (a ^ 0x80000000) < (b ^ 0x80000000);

	public static inline function stdString(v:Dynamic):String
		return GcDyn.string(v);

	public static inline function fail(msg:String)
		throw msg;

	public static inline function dynEq(a:Dynamic, b:Dynamic):Bool
		return GcDyn.eq(a, b);

	public static inline function isBoxedFloat(x:Dynamic):Bool
		return W.kind(x) == 2;

	public static inline function isBoxedBool(x:Dynamic):Bool
		return W.kind(x) == 3;

	public static inline function unboxedFloat(x:Dynamic):Float
		return W.unboxFloat(x);

	public static inline function unboxedBool(x:Dynamic):Int
		return W.unboxBool(x) ? 1 : 0;

	// ---- strings

	public static inline function len(s:String):Int
		return W.strLen(s);

	public static inline function unit(s:String, i:Int):Int
		return W.strGet(s, i);

	public static inline function chars(s:String):GcChars
		return s;

	public static inline function make(n:Int):String
		return W.strNew(n);

	// (no room for a hash: computed each time)
	public static inline function storedHash(s:String):Int
		return 0;

	public static inline function storeHash(s:String, h:Int) {}

	public static inline function setUnit(s:String, i:Int, v:Int)
		W.strSet(s, i, v);

	public static inline function copy(dst:GcChars, src:GcChars, n:Int)
		W.strCopy(dst, 0, src, 0, n);

	public static inline function copyFrom(dst:GcChars, src:GcChars, si:Int, n:Int)
		W.strCopy(dst, 0, src, si, n);

	public static inline function copyTo(dst:GcChars, di:Int, src:GcChars, n:Int)
		W.strCopy(dst, di, src, 0, n);

	// c[i, i + m) == d[0, m)
	public static inline function eqUnits(c:GcChars, i:Int, d:GcChars, m:Int):Bool {
		var k = 0;
		while (k < m && c.get(i + k) == d.get(k))
			k++;
		return k == m;
	}

	public static inline function matchAt(c:GcChars, d:GcChars, i:Int, m:Int):Bool
		return eqUnits(c, i, d, m);

	// ---- StringBuf: a GcStringBuf

	public static inline function sbNew():Dynamic
		return new GcStringBuf();

	public static inline function sbLen(b:Dynamic):Int
		return (b : GcStringBuf).len;

	public static inline function sbSetLen(b:Dynamic, n:Int)
		(b : GcStringBuf).len = n;

	public static inline function sbChars(b:Dynamic):GcChars
		return (b : GcStringBuf).chars;

	public static inline function sbCapacity(b:Dynamic):Int
		return W.strLen((b : GcStringBuf).chars);

	public static inline function sbGrow(b:Dynamic, cap:Int, n:Int) {
		var r = W.strNew(cap);
		W.strCopy(r, 0, (b : GcStringBuf).chars, 0, n);
		(b : GcStringBuf).chars = r;
	}

	// ---- arrays: of any element kind (W.arr*: elements boxed in and out where
	// the kind is not known)

	public static inline var AK_I32 = 0;
	public static inline var AK_F64 = 1;
	public static inline var AK_I64 = 2;
	public static inline var AK_PTR = 3;
	public static inline var AK_BOOL = 4;

	public static inline function arrLen(a:Dynamic):Int
		return W.arrLen(a);

	public static inline function arrKind(a:Dynamic):Int
		return W.arrKind(a);

	public static inline function elems(a:Dynamic):GcElems
		return a;

	public static inline function arrMake(kind:Int, n:Int):Dynamic
		return W.arrNew(kind, n);

	public static inline function arrCopy(r:Dynamic, a:Dynamic, n:Int)
		W.arrBlit(r, 0, a, 0, n);

	public static inline function arrCopy2(r:Dynamic, a:Dynamic, na:Int, b:Dynamic, nb:Int) {
		W.arrBlit(r, 0, a, 0, na);
		W.arrBlit(r, na, b, 0, nb);
	}

	public static inline function arrCopyFrom(r:Dynamic, a:Dynamic, pos:Int, l:Int)
		W.arrBlit(r, 0, a, pos, l);

	public static inline function arrRemoveAt(a:Dynamic, i:Int) {
		var n = W.arrLen(a);
		W.arrBlit(a, i, a, i + 1, n - i - 1);
		W.arrSetLen(a, n - 1);
	}

	// the last of n elements removed and returned
	public static inline function arrPop(a:Dynamic, n:Int):Dynamic {
		var v = (a : Array<Dynamic>)[n - 1];
		W.arrSetLen(a, n - 1);
		return v;
	}

	public static inline function arrCut(a:Dynamic, n:Int, m:Int)
		W.arrSetLen(a, n);

	public static inline function arrRotate(a:Dynamic, pos:Int, n:Int) {
		var t = W.arrGet(a, n);
		W.arrBlit(a, pos + 1, a, pos, n - pos);
		W.arrSet(a, pos, t);
	}

	public static inline function arrReverse(a:Dynamic, n:Int) {
		var i = 0, j = n - 1;
		while (i < j) {
			var t = W.arrGet(a, i);
			W.arrSet(a, i, W.arrGet(a, j));
			W.arrSet(a, j, t);
			i++;
			j--;
		}
	}

	public static inline function arrSplice(a:Dynamic, r:Dynamic, pos:Int, l:Int, n:Int) {
		W.arrBlit(r, 0, a, pos, l);
		W.arrBlit(a, pos, a, pos + l, n - pos - l);
		W.arrSetLen(a, n - l);
	}

	// ---- linear memory (the module's, for what crosses to the host)

	// the n bytes at p, copied
	public static inline function octetsAt(p:hxmc.unsafe.Ptr, n:Int):GcOctets {
		var b = scratch(n);
		W.memToBytes(b, 0, p, n);
		return b;
	}

	static var lent = hxmc.unsafe.Ptr.nil();
	static var lentCap = 0;

	// b's bytes [pos, pos + n) copied into a buffer of the linear memory kept
	// for this (hxmc.unsafe.BytesPtr.of), its address
	public static function lend(b:haxe.io.BytesData, pos:Int, n:Int):hxmc.unsafe.Ptr {
		if (pos < 0 || n < 0 || pos + n > W.bytesLen(b)) throw "OutsideBounds";
		if (n > lentCap) {
			if (!lent.isNull()) hxmc.unsafe.LibC.free(lent);
			lentCap = n < 4096 ? 4096 : n;
			lent = hxmc.unsafe.LibC.malloc(lentCap);
		}
		W.bytesToMem(lent, b, pos, n);
		return lent;
	}

	public static inline function utf8To(s:String, p:hxmc.unsafe.Ptr):Int {
		var b = scratch(3 * W.strLen(s) + 1);
		var n = hxmc.rt.Str.utf8Into(s, b);
		W.bytesToMem(p, b, 0, n + 1);
		return n;
	}

	// ---- Bytes: an array of bytes

	public static inline function bytesLen(b:Dynamic):Int
		return W.bytesLen(b);

	public static inline function octets(b:Dynamic):GcOctets
		return b;

	public static inline function bytesAllocUninit(n:Int):Dynamic
		return W.bytesNew(n);

	public static inline function bytesMove(dst:Dynamic, di:Int, src:Dynamic, si:Int, n:Int)
		W.bytesCopy(dst, di, src, si, n);

	public static inline function bytesCopyAt(dst:Dynamic, di:Int, src:Dynamic, si:Int, n:Int)
		W.bytesCopy(dst, di, src, si, n);

	public static inline function bytesCopyFrom(dst:Dynamic, src:Dynamic, si:Int, n:Int)
		W.bytesCopy(dst, 0, src, si, n);

	public static inline function copyOctets(dst:GcOctets, src:GcOctets, n:Int)
		W.bytesCopy(dst, 0, src, 0, n);

	public static inline function bytesFill(b:Dynamic, pos:Int, n:Int, v:Int)
		W.bytesFill(b, pos, v, n);

	public static function compareOctets(a:GcOctets, b:GcOctets, n:Int):Int {
		var i = 0;
		// (eight bytes a step while they are the same: an array of bytes has no wider reads)
		while (i + 8 <= n) {
			var d = (a.get(i) ^ b.get(i)) | (a.get(i + 1) ^ b.get(i + 1)) | (a.get(i + 2) ^ b.get(i + 2)) | (a.get(i + 3) ^ b.get(i + 3))
				| (a.get(i + 4) ^ b.get(i + 4)) | (a.get(i + 5) ^ b.get(i + 5)) | (a.get(i + 6) ^ b.get(i + 6)) | (a.get(i + 7) ^ b.get(i + 7));
			if (d != 0) break;
			i += 8;
		}
		while (i < n) {
			var x = a.get(i), y = b.get(i);
			if (x != y) return x - y;
			i++;
		}
		return 0;
	}

	static var scratchBytes:Dynamic = null;

	// a buffer of at least n bytes, kept for the next call
	public static function scratch(n:Int):GcOctets {
		if (scratchBytes == null || W.bytesLen(scratchBytes) < n) scratchBytes = W.bytesNew(n < 256 ? 256 : n);
		return scratchBytes;
	}

	// ---- BytesBuffer: a GcBytesBuffer

	public static inline function bbNew():Dynamic
		return new GcBytesBuffer();

	public static inline function bbLen(bb:Dynamic):Int
		return (bb : GcBytesBuffer).len;

	public static inline function bbSetLen(bb:Dynamic, n:Int)
		(bb : GcBytesBuffer).len = n;

	public static inline function bbData(bb:Dynamic):Dynamic
		return (bb : GcBytesBuffer).data;

	public static inline function bbSetData(bb:Dynamic, d:Dynamic)
		(bb : GcBytesBuffer).data = d;

	// ---- Date: a GcDate, its fields the host's (W.dateNum: op 0 a local time's
	// milliseconds, 1-7 the local fields, 8-14 the UTC ones, 15 the zone's
	// offset, 16 now)

	public static inline var F_YEAR = 1;
	public static inline var F_MON = 2;
	public static inline var F_MDAY = 3;
	public static inline var F_WDAY = 4;
	public static inline var F_HOUR = 5;
	public static inline var F_MIN = 6;
	public static inline var F_SEC = 7;
	public static inline var YEAR_BASE = 0;

	public static inline function dateOf(ms:Float):Dynamic
		return new GcDate(ms);

	public static inline function dateMs(d:Dynamic):Float
		return (d : GcDate).t;

	public static inline function dateLocal(y:Int, m:Int, d:Int, h:Int, mi:Int, s:Int):Float
		return W.dateNum(0, 0, y, m, d, h, mi, s);

	public static inline function dateNow():Float
		return W.dateNum(16, 0, 0, 0, 0, 0, 0, 0);

	public static inline function dateField(d:Dynamic, utc:Bool, f:Int):Int
		return Std.int(W.dateNum(utc ? f + 7 : f, dateMs(d), 0, 0, 0, 0, 0, 0));

	public static inline function dateFields(d:Dynamic):GcTm
		return dateMs(d);

	public static inline function timezoneOffset(d:Dynamic):Int
		return Std.int(W.dateNum(15, dateMs(d), 0, 0, 0, 0, 0, 0));

	// ---- bit patterns

	public static inline function i32ToFloat(i:Int):Float
		return W.bitsF32(i);

	public static inline function floatToI32(v:Float):Int
		return W.f32Bits(v);

	public static inline function i64ToDouble(low:Int, high:Int):Float
		// (low zero-extended: & 0xFFFFFFFF would not do it, the literal being the Int -1, all ones as an I64)
		return W.bitsF64(((high : hxmc.I64) << 32) | (((low : hxmc.I64) << 32) >>> 32));

	public static inline function doubleLow(v:Float):Int
		return W.f64Bits(v).toInt();

	public static inline function doubleHigh(v:Float):Int
		return (W.f64Bits(v) >> 32).toInt();
}

// a string's units: the string
abstract GcChars(String) from String to String {
	public inline function get(i:Int):Int
		return W.strGet(this, i);

	public inline function set(i:Int, v:Int)
		W.strSet(this, i, v);
}

// a broken-down local time: the time, its fields asked for
abstract GcTm(Float) from Float {
	public inline function get(f:Int):Int
		return Std.int(W.dateNum(f, this, 0, 0, 0, 0, 0, 0));
}

// an array's elements: the array (W.arrGet*: of the kind, else converted)
abstract GcElems(Dynamic) from Dynamic to Dynamic {
	public inline function getInt(i:Int):Int
		return W.arrGetI(this, i);

	public inline function getBool(i:Int):Int
		return W.arrGetB(this, i);

	public inline function getFloat(i:Int):Float
		return W.arrGetF(this, i);

	public inline function getI64(i:Int):hxmc.I64
		return W.arrGetL(this, i);

	public inline function getRef(i:Int):Dynamic
		return W.arrGetP(this, i);
}

// bytes: a haxe.io.BytesData (an array of bytes; Dynamic: no view of it as
// a NativeArray to take, hxmc.rt.gc.GcNArray)
abstract GcOctets(Dynamic) from Dynamic to Dynamic {
	public inline function get(i:Int):Int
		return W.bytesGet(this, i);

	public inline function set(i:Int, v:Int)
		W.bytesSet(this, i, v);

	// little-endian at byte pos
	public inline function getU16(pos:Int):Int
		return W.bytesGet(this, pos) | (W.bytesGet(this, pos + 1) << 8);

	public inline function setU16(pos:Int, v:Int) {
		W.bytesSet(this, pos, v);
		W.bytesSet(this, pos + 1, v >> 8);
	}

	public inline function setI32(pos:Int, v:Int)
		W.bytesSetI32(this, pos, v);

	public inline function setF32(pos:Int, v:Float)
		W.bytesSetI32(this, pos, W.f32Bits(v));

	public inline function setF64(pos:Int, v:Float)
		W.bytesSetI64(this, pos, W.f64Bits(v));
}

// Date: the milliseconds since the epoch
@:keep @:hxmc.wasmgc
class GcDate {
	public final t:Float;

	public function new(t)
		this.t = t;
}

// StringBuf: its units (the capacity: their length) and how many are used
@:keep @:hxmc.wasmgc
class GcStringBuf {
	public var chars:String;
	public var len = 0;

	public function new()
		chars = W.strNew(16);
}

// BytesBuffer: its bytes (the capacity: their length) and how many are used
@:keep @:hxmc.wasmgc
class GcBytesBuffer {
	public var data:Dynamic = W.bytesNew(64);
	public var len = 0;

	public function new() {}
}
