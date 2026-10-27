package hxmc.unsafe;

import haxe.io.Bytes;
import haxe.io.Error;
import hxmc.I64;

// A buffer outside the collected heap, for I/O that holds its address while
// the program runs on (docs/interop.md, "I/O buffers"): io_uring's
// submissions, IOCP's OVERLAPPED reads. The collector never moves nor frees
// it: its address (`ptr`) stays valid until `free`, across GC points, calls
// in a safe region and threads. An owned value: whoever holds it frees it
// once, after the last operation on it completed.
//
//   var buf = IoBuffer.alloc(4096);      // zeroed
//   var n = read(fd, buf.ptr, buf.length);
//   buf.blitToBytes(0, bytes, 0, n);     // or buf.view(): a Bytes over it
//   buf.free();
//
// Its memory is malloc's: a 16-byte header, then the bytes (aligned as
// malloc aligns: 16 bytes natively, 8 on wasm32; page-aligned memory for
// O_DIRECT is mmap's or VirtualAlloc's). The header's second word is a NativeArray<Byte>'s header
// (hxmc.rt.Types: T_BYTES, its words, its length), so the bytes are a
// BytesData outside the heap, which `view` wraps in a haxe.io.Bytes without
// a copy (the collector leaves references outside its spaces alone, as it
// does the static empty arrays). Accessors test their range (OutsideBounds).
abstract IoBuffer(Ptr) {
	static inline var HEADER = 16;

	// a buffer of n zeroed bytes
	public static function alloc(n:Int):IoBuffer {
		if (n < 0) throw Error.OutsideBounds;
		var p = LibC.malloc(((HEADER + n : Int) : I64));
		if (p.isNull()) throw "IoBuffer.alloc: out of memory (" + n + " bytes)";
		var words = (n + 7) >> 3;
		Mem.setI64(p, 0, (0 : I64));
		Mem.setI16(p, 8, hxmc.rt.Types.T_BYTES);
		Mem.setI16(p, 10, words < 0xFFFF ? words : 0xFFFF);
		Mem.setI32(p, 12, n);
		LibC.memset(p.add(HEADER), 0, (n : I64));
		return cast p;
	}

	// a buffer holding a copy of bytes [pos, pos + len) of b (all of b by default)
	public static function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):IoBuffer {
		if (len < 0) len = b.length - pos;
		var r = alloc(len);
		r.blitFromBytes(0, b, pos, len);
		return r;
	}

	// frees the buffer: its address, and any view of it, are invalid from here
	public inline function free():Void
		LibC.free(this);

	// the address of its first byte (stable until free)
	public var ptr(get, never):Ptr<UInt8>;

	inline function get_ptr():Ptr<UInt8>
		return this.add(HEADER);

	public var length(get, never):Int;

	inline function get_length():Int
		return Mem.getI32(this, 12);

	// [pos, pos + n) inside
	inline function inRange(pos:Int, n:Int):Bool
		return pos >= 0 && n >= 0 && pos <= length - n;

	inline function check(pos:Int, n:Int)
		if (!inRange(pos, n)) throw Error.OutsideBounds;

	public inline function get(pos:Int):Int {
		check(pos, 1);
		return Mem.getU8(this, HEADER + pos);
	}

	public inline function set(pos:Int, v:Int):Void {
		check(pos, 1);
		Mem.setI8(this, HEADER + pos, v);
	}

	// little-endian, as haxe.io.Bytes
	public inline function getUInt16(pos:Int):Int {
		check(pos, 2);
		return Mem.getU16(this, HEADER + pos);
	}

	public inline function setUInt16(pos:Int, v:Int):Void {
		check(pos, 2);
		Mem.setI16(this, HEADER + pos, v);
	}

	public inline function getInt32(pos:Int):Int {
		check(pos, 4);
		return Mem.getI32(this, HEADER + pos);
	}

	public inline function setInt32(pos:Int, v:Int):Void {
		check(pos, 4);
		Mem.setI32(this, HEADER + pos, v);
	}

	public inline function getI64(pos:Int):I64 {
		check(pos, 8);
		return Mem.getI64(this, HEADER + pos);
	}

	public inline function setI64(pos:Int, v:I64):Void {
		check(pos, 8);
		Mem.setI64(this, HEADER + pos, v);
	}

	public inline function getDouble(pos:Int):Float {
		check(pos, 8);
		return Mem.getF64(this, HEADER + pos);
	}

	public inline function setDouble(pos:Int, v:Float):Void {
		check(pos, 8);
		Mem.setF64(this, HEADER + pos, v);
	}

	public function fill(pos:Int, len:Int, value:Int):Void {
		check(pos, len);
		LibC.memset(this.add(HEADER + pos), value, (len : I64));
	}

	// len bytes of src from srcpos to pos (overlapping ranges too)
	public function blit(pos:Int, src:IoBuffer, srcpos:Int, len:Int):Void {
		check(pos, len);
		if (!src.inRange(srcpos, len)) throw Error.OutsideBounds;
		LibC.memmove(this.add(HEADER + pos), src.ptr.add(srcpos), (len : I64));
	}

	// len bytes of the heap's b from srcpos to pos
	public function blitFromBytes(pos:Int, b:Bytes, srcpos:Int, len:Int):Void {
		check(pos, len);
		if (srcpos < 0 || len < 0 || srcpos > b.length - len) throw Error.OutsideBounds;
		// (b's address is used at once: the copy is a @:hxmc.fast call)
		LibC.memcpy(this.add(HEADER + pos), BytesPtr.of(b, srcpos, len), (len : I64));
	}

	// len bytes from pos into the heap's b at dstpos
	public function blitToBytes(pos:Int, b:Bytes, dstpos:Int, len:Int):Void {
		check(pos, len);
		if (dstpos < 0 || len < 0 || dstpos > b.length - len) throw Error.OutsideBounds;
		BytesPtr.copyIn(b, dstpos, this.add(HEADER + pos), len);
	}

	// a copy of [pos, pos + len) as a new haxe.io.Bytes on the heap
	public function getBytes(pos:Int, len:Int):Bytes {
		check(pos, len);
		var b = Bytes.alloc(len);
		blitToBytes(pos, b, 0, len);
		return b;
	}

	// a haxe.io.Bytes over this buffer's bytes, without a copy: reads and
	// writes of either are the other's. It is valid until free: a view used
	// after free reads and writes freed memory.
	public function view():Bytes
		return Bytes.ofData(cast Mem.obj(this.add(HEADER)));
}
