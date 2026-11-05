// hxmc: haxe/upstream/std/haxe/io/Bytes.hx's class: a Haxe object (its
// identity, its class for reflection and serialization) holding its
// BytesData, NativeArray storage of bytes, whose bytes it reads and writes as
// a NativeArray's (no test of the index: unsafeGet); the rest is the
// runtime's (hxmc.NativeBytes, over the BytesData: hxmc.rt.Bytes). Members
// involving Int64 are inline Haxe so the runtime never builds Haxe objects.
// Its length is its BytesData's, which Dynamic access and reflection read as
// the field upstream declares (@:hxmc.lengthOf: the runtime's field table).
// A small one is allocated with its BytesData (one allocation: shared).
// Every access tests its range and throws haxe.io.Error.OutsideBounds out of
// it, reads as writes (as Eval's multi-byte reads, and HashLink's writes):
// the bytes before the data are its header, and those after it another
// object's, so a read out of range would leak them. The test is one unsigned
// comparison (inRange), which the optimizer drops where a loop or an earlier
// test proves it. Unchecked reads: fastGet (upstream's, unspecified out of
// range: the BytesData's NativeArray indexing, -D
// hxmc.native-array-outofbounds), or raw memory in @:hxmc.unsafe code
// (hxmc.unsafe.BytesPtr), or a span in a kernel (ReadOnlySpan.ofBytes).

package haxe.io;

import hxmc.NativeBytes;

class Bytes {
	@:hxmc.lengthOf("b") public var length(get, never):Int;

	var b:BytesData;

	function new(b:BytesData)
		this.b = b;

	inline function get_length():Int
		return b.length;

	public inline function get(pos:Int):Int {
		if (!inRange(pos, 1)) throw Error.OutsideBounds;
		return b.unsafeGet(pos);
	}

	public inline function set(pos:Int, v:Int):Void {
		if (!inRange(pos, 1)) throw Error.OutsideBounds;
		b.unsafeSet(pos, v);
	}

	// [pos, pos + n) inside (n a constant): one unsigned comparison of pos;
	// for more than one byte also length >= n, the same test for every access
	// of that size, reads and writes (the accesses at o, o + 4, o + 8 of one
	// function: one test, then one comparison each; length - (n - 1) cannot
	// wrap then). The comparison is a span's (Mem.spanUlt): dropped where a
	// loop proves it (Opt.condProp: `for (i in 0...b.length) b.get(i)`, a
	// block at constant offsets after a test of the length, a masked table
	// index)
	inline function inRange(pos:Int, n:Int):Bool
		return n == 1 ? hxmc.unsafe.Mem.spanUlt(pos, length) : length >= n && hxmc.unsafe.Mem.spanUlt(pos, length - (n - 1));

	public inline function blit(pos:Int, src:Bytes, srcpos:Int, len:Int):Void
		NativeBytes.blit(b, pos, src.b, srcpos, len);

	public inline function fill(pos:Int, len:Int, value:Int):Void {
		if (pos < 0 || len < 0 || pos > length - len) throw Error.OutsideBounds;
		NativeBytes.fill(b, pos, len, value);
	}

	public function sub(pos:Int, len:Int):Bytes {
		var words = (len + 7) >> 3;
		if (len > 0 && words <= SHARED_MAX && pos >= 0 && pos <= length - len) {
			var r = shared(len, words);
			// (into a new object: no overlap, the range tested; no GC point)
			hxmc.unsafe.LibC.memcpy(hxmc.unsafe.Mem.addr(r.b), hxmc.unsafe.Mem.addr(b).add(pos), (len : hxmc.I64));
			return r;
		}
		// (and the others' OutsideBounds)
		return new Bytes(NativeBytes.sub(b, pos, len));
	}

	public inline function compare(other:Bytes):Int
		return NativeBytes.compare(b, other.b);

	public inline function getDouble(pos:Int):Float {
		if (!inRange(pos, 8)) throw Error.OutsideBounds;
		return NativeBytes.getDouble(b, pos);
	}

	public inline function getFloat(pos:Int):Float {
		if (!inRange(pos, 4)) throw Error.OutsideBounds;
		return NativeBytes.getFloat(b, pos);
	}

	public inline function setDouble(pos:Int, v:Float):Void {
		if (!inRange(pos, 8)) throw Error.OutsideBounds;
		NativeBytes.setDouble(b, pos, v);
	}

	public inline function setFloat(pos:Int, v:Float):Void {
		if (!inRange(pos, 4)) throw Error.OutsideBounds;
		NativeBytes.setFloat(b, pos, v);
	}

	public inline function getUInt16(pos:Int):Int {
		if (!inRange(pos, 2)) throw Error.OutsideBounds;
		return NativeBytes.getUInt16(b, pos);
	}

	public inline function setUInt16(pos:Int, v:Int):Void {
		if (!inRange(pos, 2)) throw Error.OutsideBounds;
		NativeBytes.setUInt16(b, pos, v);
	}

	public inline function getInt32(pos:Int):Int {
		if (!inRange(pos, 4)) throw Error.OutsideBounds;
		return NativeBytes.getInt32(b, pos);
	}

	public inline function setInt32(pos:Int, v:Int):Void {
		if (!inRange(pos, 4)) throw Error.OutsideBounds;
		NativeBytes.setInt32(b, pos, v);
	}

	// (one test of the 8 bytes: setInt64 out of range writes none of them)
	public inline function getInt64(pos:Int):haxe.Int64 {
		if (!inRange(pos, 8)) throw Error.OutsideBounds;
		return haxe.Int64.make(NativeBytes.getInt32(b, pos + 4), NativeBytes.getInt32(b, pos));
	}

	public inline function setInt64(pos:Int, v:haxe.Int64):Void {
		if (!inRange(pos, 8)) throw Error.OutsideBounds;
		NativeBytes.setInt32(b, pos, v.low);
		NativeBytes.setInt32(b, pos + 4, v.high);
	}

	public inline function getString(pos:Int, len:Int, ?encoding:Encoding):String
		return NativeBytes.getString(b, pos, len, encoding);

	@:deprecated("readString is deprecated, use getString instead")
	@:noCompletion
	public inline function readString(pos:Int, len:Int):String
		return getString(pos, len);

	public function toString():String
		return NativeBytes.getString(b, 0, length, null);

	public function toHex():String
		return NativeBytes.toHex(b);

	public inline function getData():BytesData
		return b;

	// (zeroed, as the other targets leave them: hxmc.NativeArray's)
	public static inline function alloc(length:Int):Bytes {
		var words = (length + 7) >> 3;
		if (length > 0 && words <= SHARED_MAX) return shared(length, words);
		return new Bytes(new BytesData(length));
	}

	// the most words of bytes allocated with their Bytes (hxmc.rt.Boxes.arrNewN's for an Array)
	static inline var SHARED_MAX = 64;

	// a Bytes of length > 0 bytes (words of them) and its BytesData in one
	// allocation (one bump), split by writing the storage's header after the
	// Bytes' slots (hxmc.rt.Types; its one field, b, slot 0), as
	// hxmc.rt.Boxes.arrNewN does for an Array: b refers to the next object,
	// where the Bytes is (no barrier); zeroed
	static inline function shared(length:Int, words:Int):Bytes {
		var t = hxmc.unsafe.Mem.typeIndexOf(Bytes);
		var n = hxmc.rt.Types.slotCount(hxmc.rt.Types.ty(t));
		var o:Dynamic = hxmc.unsafe.Mem.alloc(n + 1 + words, t, 0); // (K_OBJ)
		var p = hxmc.unsafe.Mem.addr(o);
		hxmc.unsafe.Mem.setI64(p, -8, hxmc.rt.Types.recordHdr(t, n));
		hxmc.unsafe.Mem.setI64(p, 8 * n, hxmc.rt.Types.arrayHdr(hxmc.rt.Types.naType(hxmc.rt.Types.AK_BYTE) | (words << 16), length));
		hxmc.unsafe.Mem.setPtr(p, 0, p.add(8 * n + 8));
		return o;
	}

	public static function ofString(s:String, ?encoding:Encoding):Bytes
		return new Bytes(NativeBytes.ofString(s, encoding));

	public static function ofData(b:BytesData):Bytes
		return new Bytes(b);

	public static function ofHex(s:String):Bytes
		return new Bytes(NativeBytes.ofHex(s));

	// (upstream's: unspecified out of range, so not tested unless -D
	// hxmc.native-array-outofbounds says so, as BytesData's indexing)
	public inline static function fastGet(b:BytesData, pos:Int):Int
		return b[pos];
}
