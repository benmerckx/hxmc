package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.rt.Types.*;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.Float32;
import hxmc.unsafe.UInt16;
import hxmc.unsafe.UInt8;
import haxe.io.BytesData;
import hxmc.ReadOnlySpan;
import hxmc.Span;

// haxe.io.Bytes's natives (hxmc.NativeBytes), BytesBuffer's and FPHelper's
// (formerly in rt_std.c), written over hxmc.rt.Repr. They take and make
// haxe.io.BytesData, which a haxe.io.Bytes wraps: NativeArray storage of
// bytes (NativeArray<hxmc.Byte>: T_BYTES, its length in its header, the bytes
// from offset 0). BytesBuffer (T_BYTESBUFFER): slot 0 the length, slot 1
// its storage (its capacity).
@:keep @:allow(hxmc)
class Bytes {
	static inline function len(b:Dynamic):Int
		return Repr.bytesLen(b);

	// linear memory's: the address of the bytes (valid until the next GC point)
	static inline function bytes(b:Dynamic):Ptr
		return Mem.addr(b);

	// (haxe.io.Error.OutsideBounds, as Eval and the other targets throw it, not
	// its name: upstream's TestIO)
	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	// for callers that write all n bytes before anything reads them
	static function allocUninit(n:Int):Dynamic
		return Repr.bytesAllocUninit(n);

	// zeroed storage
	static inline function alloc(n:Int):Dynamic
		return NArray.alloc(AK_BYTE, n);

	@:hxmc.host("hxmc_NativeBytes_blit") static function blit(b:Dynamic, pos:Int, src:Dynamic, srcpos:Int, n:Int):Void {
		if (pos < 0 || srcpos < 0 || n < 0 || pos > len(b) - n || srcpos > len(src) - n) outside();
		Repr.bytesMove(b, pos, src, srcpos, n);
	}

	@:hxmc.host("hxmc_NativeBytes_fill") @:hxmc.kernel static function fill(b:BytesData, pos:Int, n:Int, v:Int):Void
		BytesView.span(b).fill(pos, n, v);

	@:hxmc.host("hxmc_NativeBytes_sub") static function sub(b:Dynamic, pos:Int, n:Int):Dynamic {
		if (pos < 0 || n < 0 || pos > len(b) - n) outside();
		var r = allocUninit(n);
		Repr.bytesCopyFrom(r, b, pos, n);
		return r;
	}

	// the difference of the first differing bytes, else of the lengths
	@:hxmc.host("hxmc_NativeBytes_compare") @:hxmc.kernel static function compare(a:BytesData, b:BytesData):Int {
		var x = BytesView.span(a), y = BytesView.span(b);
		var n = x.length < y.length ? x.length : y.length;
		var c = MemOps.compare(x.sub(0, n), y);
		return c != 0 ? c : x.length - y.length;
	}

	// (haxe.io.Bytes tests pos first: these checks are its, again)
	@:hxmc.host("hxmc_NativeBytes_getUInt16") @:hxmc.kernel static function getUInt16(b:BytesData, pos:Int):Int {
		var s:ReadOnlySpan<UInt16> = BytesView.span(b).sub(pos, 2).reinterpret();
		return s[0];
	}

	@:hxmc.host("hxmc_NativeBytes_setUInt16") @:hxmc.kernel static function setUInt16(b:BytesData, pos:Int, v:Int):Void {
		var s:Span<UInt16> = BytesView.span(b).sub(pos, 2).reinterpret();
		s[0] = v;
	}

	@:hxmc.host("hxmc_NativeBytes_getInt32") @:hxmc.kernel static function getInt32(b:BytesData, pos:Int):Int {
		var s:ReadOnlySpan<Int> = BytesView.span(b).sub(pos, 4).reinterpret();
		return s[0];
	}

	@:hxmc.host("hxmc_NativeBytes_setInt32") @:hxmc.kernel static function setInt32(b:BytesData, pos:Int, v:Int):Void {
		var s:Span<Int> = BytesView.span(b).sub(pos, 4).reinterpret();
		s[0] = v;
	}

	@:hxmc.host("hxmc_NativeBytes_getDouble") @:hxmc.kernel static function getDouble(b:BytesData, pos:Int):Float {
		var s:ReadOnlySpan<Float> = BytesView.span(b).sub(pos, 8).reinterpret();
		return s[0];
	}

	@:hxmc.host("hxmc_NativeBytes_setDouble") @:hxmc.kernel static function setDouble(b:BytesData, pos:Int, v:Float):Void {
		var s:Span<Float> = BytesView.span(b).sub(pos, 8).reinterpret();
		s[0] = v;
	}

	@:hxmc.host("hxmc_NativeBytes_getFloat") @:hxmc.kernel static function getFloat(b:BytesData, pos:Int):Float {
		var s:ReadOnlySpan<Float32> = BytesView.span(b).sub(pos, 4).reinterpret();
		return s[0];
	}

	@:hxmc.host("hxmc_NativeBytes_setFloat") @:hxmc.kernel static function setFloat(b:BytesData, pos:Int, v:Float):Void {
		var s:Span<Float32> = BytesView.span(b).sub(pos, 4).reinterpret();
		s[0] = v;
	}

	@:hxmc.host("hxmc_NativeBytes_getString") static function getString(b:Dynamic, pos:Int, n:Int, encoding:Dynamic):String {
		if (pos < 0 || n < 0 || pos > len(b) - n) outside();
		// decoding allocates: the bytes copied out of the heap first
		var small = Mem.stack(256);
		var buf = n <= 256 ? small : LibC.malloc(n);
		LibC.memcpy(buf, bytes(b).add(pos), n);
		var s = Str.ofUtf8(buf, n);
		if (buf != small) LibC.free(buf);
		return s;
	}

	@:hxmc.host("hxmc_NativeBytes_ofString") static function ofString(s:String, encoding:Dynamic):Dynamic {
		var small = Mem.stack(512);
		var cap = 3 * Str.len(s) + 1;
		var buf = cap <= 512 ? small : LibC.malloc(cap);
		var n = Str.utf8Into(s, buf);
		var b = allocUninit(n);
		LibC.memcpy(bytes(b), buf, n);
		if (buf != small) LibC.free(buf);
		return b;
	}

	// haxe.Resource's bytes (hxmc.NativeResource): the table DataGen.resources
	// writes in the read-only data: per resource, the offset of its bytes from
	// the table and their length (32 bits each), the bytes after it; outside
	// the heap, so they stay where they are while the copy is allocated.
	@:hxmc.host("hxmc_NativeResource_bytes") static function resourceBytes(i:Int):Dynamic {
		var t = Mem.sym("hxmc_resources");
		var n = Mem.getI32(t, 8 * i + 4);
		var b = allocUninit(n);
		LibC.memcpy(bytes(b), t.add(Mem.getI32(t, 8 * i)), n);
		return b;
	}

	// (decoded where the bytes are: linear memory's, without a copy)
	@:hxmc.host("hxmc_NativeResource_string") static function resourceString(i:Int):String {
		var t = Mem.sym("hxmc_resources");
		return Str.ofUtf8(t.add(Mem.getI32(t, 8 * i)), Mem.getI32(t, 8 * i + 4));
	}

	@:hxmc.host("hxmc_NativeBytes_toHex") static function toHex(b:Dynamic):String {
		var n = len(b);
		var s = Str.make1(2 * n);
		var d = Str.chars1(s), p = Repr.octets(b);
		inline function hex(v:Int):Int
			return v < 10 ? 48 + v : 87 + v;
		for (i in 0...n) {
			var v = p.get(i);
			d.set(2 * i, hex(v >> 4));
			d.set(2 * i + 1, hex(v & 15));
		}
		return s;
	}

	@:hxmc.host("hxmc_NativeBytes_ofHex") static function ofHex(s:String):Dynamic {
		var n = Str.len(s) >> 1;
		var b = allocUninit(n);
		var p = Repr.octets(b);
		for (i in 0...n) {
			var v = 0;
			for (k in 0...2) {
				var u = Str.unit(s, 2 * i + k);
				v = v * 16 + (u >= 48 && u <= 57 ? u - 48 : u >= 97 && u <= 102 ? u - 87 : u >= 65 && u <= 70 ? u - 55 : 0);
			}
			p.set(i, v);
		}
		return b;
	}

	// ---- BytesBuffer: its length and its bytes (Repr's)

	static inline function bbLen(bb:Dynamic):Int
		return Repr.bbLen(bb);

	static inline function bbData(bb:Dynamic):Dynamic
		return Repr.bbData(bb);

	@:hxmc.host("haxe_io_BytesBuffer_new") static function bbNew():Dynamic
		return Repr.bbNew();

	@:hxmc.host("haxe_io_BytesBuffer_get_length") @:hxmc.kernel static function bbGetLength(bb:Dynamic):Int
		return BytesView.bufLength(bb);

	// room for n more bytes
	static function reserve(bb:Dynamic, n:Int) {
		var l = bbLen(bb);
		var cap = len(bbData(bb));
		if (l + n <= cap) return;
		var ncap = cap * 2;
		if (ncap < l + n) ncap = l + n;
		var nd = alloc(ncap);
		Repr.copyOctets(Repr.octets(nd), Repr.octets(bbData(bb)), l);
		Repr.bbSetData(bb, nd);
	}

	@:hxmc.host("haxe_io_BytesBuffer_addByte") static function addByte(bb:Dynamic, v:Int):Void {
		reserve(bb, 1);
		var l = bbLen(bb);
		Repr.octets(bbData(bb)).set(l, v);
		Repr.bbSetLen(bb, l + 1);
	}

	@:hxmc.host("haxe_io_BytesBuffer_addData") static function addBytes(bb:Dynamic, b:Dynamic, pos:Int, n:Int):Void {
		if (pos < 0 || n < 0 || pos > len(b) - n) outside();
		reserve(bb, n);
		var l = bbLen(bb);
		Repr.bytesCopyAt(bbData(bb), l, b, pos, n);
		Repr.bbSetLen(bb, l + n);
	}

	static function add(bb:Dynamic, b:Dynamic):Void
		addBytes(bb, b, 0, len(b));

	@:hxmc.host("haxe_io_BytesBuffer_addString") static function addString(bb:Dynamic, s:String, encoding:Dynamic):Void
		add(bb, ofString(s, encoding));

	@:hxmc.host("haxe_io_BytesBuffer_addInt32") static function addInt32(bb:Dynamic, v:Int):Void {
		reserve(bb, 4);
		var l = bbLen(bb);
		Repr.octets(bbData(bb)).setI32(l, v);
		Repr.bbSetLen(bb, l + 4);
	}

	@:hxmc.host("haxe_io_BytesBuffer_addFloat") static function addFloat(bb:Dynamic, v:Float):Void {
		reserve(bb, 4);
		var l = bbLen(bb);
		Repr.octets(bbData(bb)).setF32(l, v);
		Repr.bbSetLen(bb, l + 4);
	}

	@:hxmc.host("haxe_io_BytesBuffer_addDouble") static function addDouble(bb:Dynamic, v:Float):Void {
		reserve(bb, 8);
		var l = bbLen(bb);
		Repr.octets(bbData(bb)).setF64(l, v);
		Repr.bbSetLen(bb, l + 8);
	}

	@:hxmc.host("haxe_io_BytesBuffer_getData") static function getBytes(bb:Dynamic):Dynamic
		return sub(bbData(bb), 0, bbLen(bb));

	// ---- FPHelper (bit patterns: Repr's, Mem's bit casts)

	@:hxmc.host("haxe_io_FPHelper_i32ToFloat") @:hxmc.kernel static function i32ToFloat(i:Int):Float
		return Repr.i32ToFloat(i);

	@:hxmc.host("haxe_io_FPHelper_floatToI32") @:hxmc.kernel static function floatToI32(v:Float):Int
		return Repr.floatToI32(v);

	@:hxmc.host("haxe_io_FPHelper_i64ToDouble") @:hxmc.kernel static function i64ToDouble(low:Int, high:Int):Float
		return Repr.i64ToDouble(low, high);

	@:hxmc.host("haxe_io_FPHelper_doubleLow") @:hxmc.kernel static function doubleLow(v:Float):Int
		return Repr.doubleLow(v);

	@:hxmc.host("haxe_io_FPHelper_doubleHigh") @:hxmc.kernel static function doubleHigh(v:Float):Int
		return Repr.doubleHigh(v);
}
