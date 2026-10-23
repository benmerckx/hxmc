package hxmc.unsafe;

import hxmc.I64;

// Temporary native memory (docs/plans/lowlevel.md, "First milestone"): a bump
// allocator over malloc'ed chunks, for strings and buffers passed to C.
// Everything allocated is freed at once, when the scope ends:
//
//   Arena.scoped(a -> {
//     var path = a.cstring(name);            // UTF-8 + NUL, copied once
//     var buf:Ptr<UInt8> = a.alloc(4096);    // zeroed
//     var n = Posix.read(fd, buf, 4096);
//     ...
//   });                                      // freed here, also on exceptions
//
// The arena itself lives in malloc'ed memory (no GC object): create/dispose
// work in @:hxmc.noGc code too. Memory never moves, so pointers into it may
// be kept across GC points and passed to blocking C calls.
abstract Arena(Ptr) {
	// header: the current chunk's free part [cur, end), the chunk list (each
	// chunk starts with the next one's address)
	static inline var CUR = 0;
	static inline var END = 8;
	static inline var CHUNKS = 16;
	static inline var HEADER = 24;
	static inline var FIRST = 4096;

	// runs f with a new arena, frees the arena when f returns or throws
	public static inline function scoped(f:Arena->Void):Void {
		var a = create();
		try f(a) catch (e:Dynamic) {
			a.dispose();
			throw e;
		}
		a.dispose();
	}

	// the same, for an f that returns a value (Haxe cannot overload scoped on Void)
	public static inline function scopedValue<R>(f:Arena->R):R {
		var a = create();
		var r = try f(a) catch (e:Dynamic) {
			a.dispose();
			throw e;
		}
		a.dispose();
		return r;
	}

	@:hxmc.noGc public static function create():Arena {
		var p = LibC.malloc((FIRST : I64));
		Mem.setPtr(p, CUR, p.add(HEADER + 8));
		Mem.setPtr(p, END, p.add(FIRST));
		Mem.setPtr(p, CHUNKS, Ptr.nil());
		Mem.setPtr(p, HEADER, Ptr.nil());
		return cast p;
	}

	// frees every chunk and the arena
	@:hxmc.noGc public function dispose():Void {
		var c:Ptr = Mem.getPtr(this, CHUNKS);
		while (!c.isNull()) {
			var next = Mem.getPtr(c, 0);
			LibC.free(c);
			c = next;
		}
		LibC.free(this);
	}

	// `bytes` zeroed bytes aligned to `align` (a power of two, at most 16)
	@:hxmc.noGc public function alloc(bytes:Int, align:Int = 8):Ptr {
		var cur:Ptr = Mem.getPtr(this, CUR);
		var mask:I64 = (align - 1 : I64);
		var p = Ptr.ofI64((cur.toI64() + mask) & ~mask);
		if (Mem.ult(Mem.getPtr(this, END).toI64(), p.toI64() + (bytes : I64))) {
			// a new chunk: twice the last one, or the request's size
			var size = FIRST * 2;
			while (size < bytes + 32)
				size *= 2;
			var c = LibC.malloc((size : I64));
			Mem.setPtr(c, 0, Mem.getPtr(this, CHUNKS));
			Mem.setPtr(this, CHUNKS, c);
			p = Ptr.ofI64((c.add(16).toI64() + mask) & ~mask);
			Mem.setPtr(this, END, c.add(size));
		}
		Mem.setPtr(this, CUR, p.add(bytes));
		LibC.memset(p, 0, (bytes : I64));
		return p;
	}

	// a zeroed instance of the @:hxmc.struct class c
	public inline function make<T>(c:Class<T>):Ptr<T>
		return alloc(Struct.sizeOf(c), Struct.alignOf(c) > 16 ? 16 : Struct.alignOf(c));

	// n zeroed instances of the @:hxmc.struct class c
	public inline function makeArray<T>(c:Class<T>, n:Int):Ptr<T>
		return alloc(Struct.sizeOf(c) * n, Struct.alignOf(c) > 16 ? 16 : Struct.alignOf(c));

	// the same as a bounds-checked Slice
	public inline function slice<T>(c:Class<T>, n:Int):Slice<T>
		return new Slice(makeArray(c, n), n);

	// s as UTF-8 with a NUL (null for null)
	public function cstring(s:String):CString {
		if (s == null) return Ptr.nil();
		var p:Ptr<UInt8> = alloc(3 * s.length + 1, 1);
		hxmc.rt.Repr.utf8To(s, p);
		return p;
	}

	// s as UTF-16 with a NUL (Windows' wide strings)
	public function wstring(s:String):Ptr<UInt16> {
		if (s == null) return Ptr.nil();
		var n = s.length;
		var p:Ptr<UInt16> = alloc(2 * n + 2, 2);
		LibC.memcpy(p, Mem.addr(s).add(4), (2 * n : I64)); // (the units, after the length: hxmc.rt.Types)
		return p;
	}

	// a copy of b followed by a NUL (C strings in Bytes)
	public function copyBytesZ(b:haxe.io.Bytes):CString {
		var n = b.length;
		var p:Ptr<UInt8> = alloc(n + 1, 1);
		LibC.memcpy(p, Mem.addr(b.getData()), (n : I64));
		return p;
	}

	// a copy of bytes [pos, pos + len) of b
	public function copyBytes(b:haxe.io.Bytes, pos:Int = 0, len:Int = -1):Ptr<UInt8> {
		if (len < 0) len = b.length - pos;
		if (pos < 0 || len < 0 || pos + len > b.length) throw haxe.io.Error.OutsideBounds;
		var p:Ptr<UInt8> = alloc(len, 1);
		LibC.memcpy(p, Mem.addr(b.getData()).add(pos), (len : I64));
		return p;
	}
}
