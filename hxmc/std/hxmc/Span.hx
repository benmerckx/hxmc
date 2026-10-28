package hxmc;

import haxe.io.Bytes;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// A checked, writable view of memory (docs/interop.md, "Spans"): elements of
// T (a C scalar or a @:hxmc.struct) from an address, and their number. A
// value of two words; ReadOnlySpan<T> is the view that cannot be written
// through, and a Span converts to one.
//
// A span exists only in GC-free code (@:hxmc.gcfree, @:hxmc.blocking): as a
// parameter, a local or a result, never a field, a static, an element, a
// capture. GC code makes one only as an argument of a direct call of a
// GC-free function, which lends the memory for that call:
//
//   var sum = Kernel.adler(ReadOnlySpan.ofBytes(bytes));
//   var e = Png.decode(ReadOnlySpan.ofIoBuffer(file), Span.ofIoBuffer(rgba));
//
// Accesses are range-checked (a failure ends the program: GC-free code
// cannot throw); the compiler expands them (FnLower.spanCall).
abstract Span<T>(SpanData) {
	// the number of elements
	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	// element i (0 <= i < length); s[i] += v too (Haxe's compound array
	// access wants inline bodies: the externs elem and setElem are the accesses)
	@:arrayAccess inline function get(i:Int):T
		return elem(i);

	@:arrayAccess inline function set(i:Int, v:T):T
		return setElem(i, v);

	extern function elem(i:Int):T;

	extern function setElem(i:Int, v:T):T;

	// elements pos .. pos + len - 1: the same memory
	extern public function sub(pos:Int, len:Int):Span<T>;

	// the same bytes as elements of U (length * size(T) / size(U) of them,
	// rounded down): `var words:Span<Int> = bytes.reinterpret();`
	extern public function reinterpret<U>():Span<U>;

	// len elements of src from srcpos to pos (overlapping ones too)
	extern public function blit(pos:Int, src:ReadOnlySpan<T>, srcpos:Int, len:Int):Void;

	// v in elements pos .. pos + len - 1
	extern public function fill(pos:Int, len:Int, v:T):Void;

	@:to extern function toReadOnly():ReadOnlySpan<T>;

	// a call's argument (GC code: only so): bytes [pos, pos + len) of b, len
	// -1 to its end; the callee is GC-free and never enters a safe region (a
	// collection would move b). The range is checked in the caller
	// (haxe.io.Error.OutsideBounds).
	extern public static function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):Span<UInt8>;

	// a call's argument (GC code: only so): bytes [pos, pos + len) of buf, len
	// -1 to its end; the callee is GC-free (@:hxmc.blocking too)
	extern public static function ofIoBuffer(buf:IoBuffer, pos:Int = 0, len:Int = -1):Span<UInt8>;

	// length elements of T at p, as their owner vouches (@:hxmc.unsafe code,
	// or a call's argument in GC code: a pool's glue)
	extern public static function unsafeOf<T>(p:Ptr<T>, length:Int):Span<T>;
}

// (a span's two words; its layout is FnLower.spanCall's)
@:noCompletion @:hxmc.struct class SpanData {
	public var ptr:Ptr;
	public var length:Int;
}

// (what FnLower.spanCall calls; kept: the calls appear while lowering)
@:noCompletion @:keep class SpanSupport {
	// [pos, pos + len) inside n, len -1 to the end: its length, or -1
	static inline function range(n:Int, pos:Int, len:Int):Int {
		if (len == -1) len = n - pos;
		return pos < 0 || len < 0 || pos > n - len ? -1 : len;
	}

	// (GC code: an argument's range, else OutsideBounds)
	public static function bytesRange(b:Bytes, pos:Int, len:Int):Int {
		var r = range(b.length, pos, len);
		if (r < 0) throw haxe.io.Error.OutsideBounds;
		return r;
	}

	public static function ioRange(buf:IoBuffer, pos:Int, len:Int):Int {
		var r = range(ioLength(buf), pos, len);
		if (r < 0) throw haxe.io.Error.OutsideBounds;
		return r;
	}

	// (GC-free code: the program ends)
	@:hxmc.unsafe @:hxmc.gcfree public static function ioRangeFatal(buf:IoBuffer, pos:Int, len:Int, where:Ptr):Int {
		var n = ioLength(buf), r = range(n, pos, len);
		if (r < 0) badRange(pos, len, n, where);
		return r;
	}

	@:hxmc.unsafe @:hxmc.gcfree static function ioLength(buf:IoBuffer):Int
		return buf.length;

	@:hxmc.unsafe @:hxmc.gcfree public static function ioAddr(buf:IoBuffer, pos:Int):Ptr
		return buf.ptr.add(pos);

	// the address of b's byte pos: valid while nothing collects (Facts.checkHeapSpans:
	// the call it is taken for is GC-free and enters no safe region)
	@:hxmc.unsafe public static function bytesAddr(b:Bytes, pos:Int):Ptr
		return hxmc.unsafe.BytesPtr.of(b, pos, 0);

	// a failed check: the program ends (GC-free code cannot throw)
	@:hxmc.unsafe @:hxmc.gcfree public static function outOfRange(i:Int, n:Int, where:Ptr):Void {
		var r = report("hxmc: span index ");
		r.int(i, 0);
		r.str(" out of range [0, ");
		r.int(n, 0);
		end(r, where);
	}

	@:hxmc.unsafe @:hxmc.gcfree public static function badRange(pos:Int, len:Int, n:Int, where:Ptr):Void {
		var r = report("hxmc: span range ");
		r.int(pos, 0);
		r.str(" + ");
		r.int(len, 0);
		r.str(" out of range [0, ");
		r.int(n, 0);
		end(r, where);
	}

	static inline function report(what:String):hxmc.rt.Os.Report {
		var r = new hxmc.rt.Os.Report(hxmc.unsafe.Mem.stack(hxmc.rt.Os.Report.BYTES));
		r.str(what);
		return r;
	}

	@:hxmc.unsafe @:hxmc.gcfree static function end(r:hxmc.rt.Os.Report, where:Ptr) {
		r.str(") at ");
		r.cstr(where, 0, -1);
		r.ch(10);
		r.flush();
		hxmc.rt.Os.exit(2);
	}

	@:hxmc.unsafe @:hxmc.gcfree public static function move(dst:Ptr, src:Ptr, bytes:hxmc.I64):Void
		hxmc.unsafe.LibC.memmove(dst, src, bytes);
}
