package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.rt.Types.*;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// haxe.io.Bytes, BytesBuffer and FPHelper natives (formerly in rt_std.c),
// written over hxmc.rt.Repr for both runtimes (@:hxmc.anyHeap). In linear
// memory Bytes is K_RAW, int32 length, the bytes from offset 8, and
// BytesBuffer (T_BYTESBUFFER) slot 0 the length, slot 1 a Bytes (its
// capacity); under -D hxmc.wasm-gc a Bytes is an array of bytes whose
// accessors are instructions (hxmc.wasmgc.FuncGen).
@:keep @:allow(hxmc) @:hxmc.anyHeap
class Bytes {
	static inline function len(b:Dynamic):Int
		return Repr.bytesLen(b);

	// linear memory's: the address of the bytes (valid until the next GC point)
	static inline function bytes(b:Dynamic):Ptr
		return Mem.addr(b).add(8);

	// (haxe.io.Error.OutsideBounds, as Eval and the other targets throw it, not
	// its name: upstream's TestIO)
	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	// for callers that write all n bytes before anything reads them
	static function allocUninit(n:Int):Dynamic
		return Repr.bytesAllocUninit(n);

	#if !(hxmc.wasm_gc)
	// zeroed, as hxc's rt_alloc and the other targets leave them (the API
	// leaves the contents unspecified, but programs read them: the crypto
	// library's Sha512 pads its blocks with Bytes.alloc's zeros); a nursery
	// reused after a minor collection holds the bytes of dead objects
	@:hxmc.host("haxe_io_Bytes_alloc") static function alloc(n:Int):Dynamic {
		var b = Mem.alloc((n + 15) >> 3, T_BYTES, K_RAW);
		Mem.setI32(Mem.addr(b), 0, n);
		return b;
	}

	@:hxmc.host("haxe_io_Bytes_get_length") @:hxmc.noGc static function getLength(b:Dynamic):Int
		return len(b);

	@:hxmc.host("haxe_io_Bytes_get") @:hxmc.noGc static function get(b:Dynamic, pos:Int):Int
		return Mem.getU8At(Mem.addr(b), 8, pos);

	@:hxmc.host("haxe_io_Bytes_set") @:hxmc.noGc static function set(b:Dynamic, pos:Int, v:Int):Void
		Mem.setU8At(Mem.addr(b), 8, pos, v);
	#else
	static inline function alloc(n:Int):Dynamic
		return haxe.io.Bytes.alloc(n);
	#end

	@:hxmc.host("haxe_io_Bytes_blit") static function blit(b:Dynamic, pos:Int, src:Dynamic, srcpos:Int, n:Int):Void {
		if (pos < 0 || srcpos < 0 || n < 0 || pos + n > len(b) || srcpos + n > len(src)) outside();
		Repr.bytesMove(b, pos, src, srcpos, n);
	}

	@:hxmc.host("haxe_io_Bytes_fill") @:hxmc.noGc static function fill(b:Dynamic, pos:Int, n:Int, v:Int):Void
		Repr.bytesFill(b, pos, n, v);

	@:hxmc.host("haxe_io_Bytes_sub") static function sub(b:Dynamic, pos:Int, n:Int):Dynamic {
		if (pos < 0 || n < 0 || pos + n > len(b)) outside();
		var r = allocUninit(n);
		Repr.bytesCopyFrom(r, b, pos, n);
		return r;
	}

	// the difference of the first differing bytes, else of the lengths
	@:hxmc.host("haxe_io_Bytes_compare") @:hxmc.noGc static function compare(a:Dynamic, b:Dynamic):Int {
		var na = len(a), nb = len(b);
		var n = na < nb ? na : nb;
		var pa = Repr.octets(a), pb = Repr.octets(b);
		var c = Repr.compareOctets(pa, pb, n);
		if (c != 0) return c;
		return na - nb;
	}

	@:hxmc.host("haxe_io_Bytes_getUInt16") @:hxmc.noGc static function getUInt16(b:Dynamic, pos:Int):Int
		return Repr.octets(b).getU16(pos);

	@:hxmc.host("haxe_io_Bytes_setUInt16") @:hxmc.noGc static function setUInt16(b:Dynamic, pos:Int, v:Int):Void
		Repr.octets(b).setU16(pos, v);

	#if !(hxmc.wasm_gc)
	@:hxmc.host("haxe_io_Bytes_getInt32") @:hxmc.noGc static function getInt32(b:Dynamic, pos:Int):Int
		return Mem.getI32(bytes(b), pos);

	@:hxmc.host("haxe_io_Bytes_setInt32") @:hxmc.noGc static function setInt32(b:Dynamic, pos:Int, v:Int):Void
		Mem.setI32(bytes(b), pos, v);

	@:hxmc.host("haxe_io_Bytes_getDouble") @:hxmc.noGc static function getDouble(b:Dynamic, pos:Int):Float
		return Mem.getF64(bytes(b), pos);

	@:hxmc.host("haxe_io_Bytes_setDouble") @:hxmc.noGc static function setDouble(b:Dynamic, pos:Int, v:Float):Void
		Mem.setF64(bytes(b), pos, v);

	@:hxmc.host("haxe_io_Bytes_getFloat") @:hxmc.noGc static function getFloat(b:Dynamic, pos:Int):Float
		return Mem.getF32(bytes(b), pos);

	@:hxmc.host("haxe_io_Bytes_setFloat") @:hxmc.noGc static function setFloat(b:Dynamic, pos:Int, v:Float):Void
		Mem.setF32(bytes(b), pos, v);
	#end

	@:hxmc.host("haxe_io_Bytes_getString") static function getString(b:Dynamic, pos:Int, n:Int, encoding:Dynamic):String {
		if (pos < 0 || n < 0 || pos + n > len(b)) outside();
		#if (hxmc.wasm_gc)
		return Str.decode(b, pos, pos + n);
		#else
		// decoding allocates: the bytes copied out of the heap first
		var small = Mem.stack(256);
		var buf = n <= 256 ? small : LibC.malloc(n);
		LibC.memcpy(buf, bytes(b).add(pos), n);
		var s = Str.ofUtf8(buf, n);
		if (buf != small) LibC.free(buf);
		return s;
		#end
	}

	@:hxmc.host("haxe_io_Bytes_toString") static function toString(b:Dynamic):String
		return getString(b, 0, len(b), null);

	@:hxmc.host("haxe_io_Bytes_ofString") static function ofString(s:String, encoding:Dynamic):Dynamic {
		#if (hxmc.wasm_gc)
		// (encoded into a buffer kept for this, then copied)
		var buf = hxmc.rt.gc.GcRepr.scratch(3 * Str.len(s) + 1);
		var n = Str.utf8Into(s, buf);
		var b = allocUninit(n);
		Repr.copyOctets(b, buf, n);
		return b;
		#else
		var small = Mem.stack(512);
		var cap = 3 * Str.len(s) + 1;
		var buf = cap <= 512 ? small : LibC.malloc(cap);
		var n = Str.utf8Into(s, buf);
		var b = allocUninit(n);
		LibC.memcpy(bytes(b), buf, n);
		if (buf != small) LibC.free(buf);
		return b;
		#end
	}

	@:hxmc.host("haxe_io_Bytes_toHex") static function toHex(b:Dynamic):String {
		var n = len(b);
		var s = Str.make(2 * n);
		var d = Str.chars(s), p = Repr.octets(b);
		inline function hex(v:Int):Int
			return v < 10 ? 48 + v : 87 + v;
		for (i in 0...n) {
			var v = p.get(i);
			d.set(2 * i, hex(v >> 4));
			d.set(2 * i + 1, hex(v & 15));
		}
		return s;
	}

	@:hxmc.host("haxe_io_Bytes_ofHex") static function ofHex(s:String):Dynamic {
		var n = Str.len(s) >> 1;
		var b = allocUninit(n);
		var c = Str.chars(s), p = Repr.octets(b);
		for (i in 0...n) {
			var v = 0;
			for (k in 0...2) {
				var u = c.get(2 * i + k);
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

	@:hxmc.host("haxe_io_BytesBuffer_get_length") @:hxmc.noGc static function bbGetLength(bb:Dynamic):Int
		return bbLen(bb);

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

	@:hxmc.host("haxe_io_BytesBuffer_addBytes") static function addBytes(bb:Dynamic, b:Dynamic, pos:Int, n:Int):Void {
		if (pos < 0 || n < 0 || pos + n > len(b)) outside();
		reserve(bb, n);
		var l = bbLen(bb);
		Repr.bytesCopyAt(bbData(bb), l, b, pos, n);
		Repr.bbSetLen(bb, l + n);
	}

	@:hxmc.host("haxe_io_BytesBuffer_add") static function add(bb:Dynamic, b:Dynamic):Void
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

	@:hxmc.host("haxe_io_BytesBuffer_getBytes") static function getBytes(bb:Dynamic):Dynamic
		return sub(bbData(bb), 0, bbLen(bb));

	// ---- FPHelper (bit patterns: Repr's)

	@:hxmc.host("haxe_io_FPHelper_i32ToFloat") @:hxmc.noGc static function i32ToFloat(i:Int):Float
		return Repr.i32ToFloat(i);

	@:hxmc.host("haxe_io_FPHelper_floatToI32") @:hxmc.noGc static function floatToI32(v:Float):Int
		return Repr.floatToI32(v);

	@:hxmc.host("haxe_io_FPHelper_i64ToDouble") @:hxmc.noGc static function i64ToDouble(low:Int, high:Int):Float
		return Repr.i64ToDouble(low, high);

	@:hxmc.host("haxe_io_FPHelper_doubleLow") @:hxmc.noGc static function doubleLow(v:Float):Int
		return Repr.doubleLow(v);

	@:hxmc.host("haxe_io_FPHelper_doubleHigh") @:hxmc.noGc static function doubleHigh(v:Float):Int
		return Repr.doubleHigh(v);
}
