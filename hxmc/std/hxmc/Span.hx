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
// A span exists only in kernels (@:hxmc.kernel, @:hxmc.blocking): as a
// parameter, a local or a result, never a field, a static, an element, a
// capture. GC code makes one only as an argument of a direct call of a
// kernel, which lends the memory for that call:
//
//   var sum = Kernel.adler(ReadOnlySpan.ofBytes(bytes));
//   var e = Png.decode(ReadOnlySpan.ofIoBuffer(file), Span.ofIoBuffer(rgba));
//
// Accesses are range-checked (a failure ends the program: a kernel
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

	// the 8 (getI64) or 4 (getI32) bytes from element i on as one integer
	// (little-endian, any alignment), checked as sub(i, 8 / size(T)) is: of
	// elements of 1, 2, 4 or 8 bytes (a word at a time over a string's units)
	extern public function getI64(i:Int):hxmc.I64;

	extern public function getI32(i:Int):Int;

	// the same bytes as elements of U (length * size(T) / size(U) of them,
	// rounded down): `var words:Span<Int> = bytes.reinterpret();`
	extern public function reinterpret<U>():Span<U>;

	// len elements of src from srcpos to pos (overlapping ones too)
	extern public function blit(pos:Int, src:ReadOnlySpan<T>, srcpos:Int, len:Int):Void;

	// v in elements pos .. pos + len - 1
	extern public function fill(pos:Int, len:Int, v:T):Void;

	// atomic accesses of element i, checked as s[i] is: of Int, UInt (and
	// their typedefs Int32, UInt32) and Int64 elements, a compile error for
	// others. Sequentially consistent (hxmc.unsafe.Atomic's): a load
	// acquires, a store releases
	extern public function load(i:Int):T;

	// (hxmc.simd: 16, 8 or 4 bytes from byte pos * size(T), checked: op names
	// the load, v128.load, v128.load64_zero or v128.load32_zero)
	@:noCompletion extern public function vload(op:String, pos:Int):hxmc.simd.V128;

	extern public function store(i:Int, v:T):Void;

	// (hxmc.simd: v128.store, v128.store64_lane, v128.store32_lane)
	@:noCompletion extern public function vstore(op:String, pos:Int, v:hxmc.simd.V128):Void;

	// replacement into element i if it holds expected; the value it held
	extern public function compareExchange(i:Int, expected:T, replacement:T):T;

	// v added to element i, v into element i: the value it held (atomic, as load)
	extern public function add(i:Int, v:T):T;

	extern public function exchange(i:Int, v:T):T;

	@:to extern function toReadOnly():ReadOnlySpan<T>;

	// a call's argument (GC code: only so): bytes [pos, pos + len) of b, len
	// -1 to its end; the callee is GC-free and never enters a safe region (a
	// collection would move b). The range is checked in the caller
	// (haxe.io.Error.OutsideBounds).
	extern public static function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):Span<UInt8>;

	// a call's argument (GC code: only so): bytes [pos, pos + len) of buf, len
	// -1 to its end; the callee is GC-free (@:hxmc.blocking too)
	extern public static function ofIoBuffer(buf:IoBuffer, pos:Int = 0, len:Int = -1):Span<UInt8>;

	// a call's argument in GC code: bytes [pos, pos + len) of buf, len -1 to
	// its end, lent to that call (close() throws meanwhile); any callee
	extern public static function ofBuffer(buf:hxmc.Buffer, pos:Int = 0, len:Int = -1):Span<UInt8>;

	// a call's argument: x (a variable: a local, a field, a static) as a span
	// of one, copied in for the call and back after it: an out-parameter
	extern public static function of<T>(x:T):Span<T>;

	// a call's argument in GC code: the elements of a (scalars or structs)
	// copied into C memory for the call and back into a after it: many
	// out-structs (`Span.ofArray(rects)`)
	extern public static function ofArray<T>(a:Array<T>):Span<T>;

	// length elements of T at p, as their owner vouches (@:hxmc.unsafe code,
	// or a call's argument in GC code: a pool's glue)
	extern public static function unsafeOf<T>(p:Ptr<T>, length:Int):Span<T>;

	// n (a constant) zeroed elements in the kernel's frame (a kernel's only):
	// scratch that lives while the kernel runs, never its result
	// (`var t:Span<Int> = Span.stack(64);`)
	extern public static function stack<T>(n:Int):Span<T>;
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

	@:hxmc.unsafe(gc) public static function ioRange(buf:IoBuffer, pos:Int, len:Int):Int {
		var r = range(ioLength(buf), pos, len);
		if (r < 0) throw haxe.io.Error.OutsideBounds;
		return r;
	}

	// (a kernel: the program ends)
	@:hxmc.unsafe @:hxmc.kernel public static function ioRangeFatal(buf:IoBuffer, pos:Int, len:Int, where:Ptr):Int {
		var n = ioLength(buf), r = range(n, pos, len);
		if (r < 0) badRange(pos, len, n, where);
		return r;
	}

	@:hxmc.unsafe @:hxmc.kernel static function ioLength(buf:IoBuffer):Int
		return buf.length;

	@:hxmc.unsafe @:hxmc.kernel public static function ioAddr(buf:IoBuffer, pos:Int):Ptr
		return buf.ptr.add(pos);

	// the address of b's byte pos: valid while nothing collects (Facts.checkHeapSpans:
	// the call it is taken for is GC-free and enters no safe region)
	@:hxmc.unsafe public static function bytesAddr(b:Bytes, pos:Int):Ptr
		return hxmc.unsafe.BytesPtr.of(b, pos, 0);

	// a failed check: the program ends (a kernel cannot throw)
	@:hxmc.unsafe @:hxmc.kernel public static function outOfRange(i:Int, n:Int, where:Ptr):Void {
		var r = report("hxmc: span index ");
		r.int(i, 0);
		r.str(" out of range [0, ");
		r.int(n, 0);
		end(r, where);
	}

	// a Buffer lent to a call (Span.ofBuffer, FnLower.spanCall): its range as
	// the arguments are evaluated (OutsideBounds, closed); once they are, the
	// span lent (-1: it closed meanwhile, an empty span), released after the call
	public static function bufferRange(b:Buffer, pos:Int, len:Int):Int
		return b.range(pos, len);

	@:hxmc.unsafe public static function bufferTake(b:Buffer, n:Int):Int
		return b.take(n);

	@:hxmc.unsafe public static function bufferRelease(b:Buffer):Void
		b.release();

	@:hxmc.unsafe public static function bufferAddr(b:Buffer, pos:Int):hxmc.I64
		return b.addr(pos);

	// a String passed to a typed C call: a malloc'ed NUL-terminated UTF-8
	// copy, 0 for null; freed after the call (cfree: FnLower.typedCall)
	@:hxmc.unsafe public static function cstring(s:String):hxmc.I64
		return s == null ? 0 : hxmc.rt.Str.toUtf8(s).toI64();

	// (Span.ofArray: C memory for the elements, cfree'd after the call)
	@:hxmc.unsafe public static function alloc(bytes:hxmc.I64):hxmc.I64
		return hxmc.unsafe.LibC.malloc(bytes == (0 : hxmc.I64) ? (8 : hxmc.I64) : bytes).toI64();

	@:hxmc.unsafe public static function cfree(p:hxmc.I64):Void
		if (p != (0 : hxmc.I64)) hxmc.unsafe.LibC.free(new Ptr(p));

	// a String result of a typed C call: C's NUL-terminated UTF-8 copied, null for NULL
	@:hxmc.unsafe(gc) public static function cresult(p:hxmc.I64):String {
		if (p == (0 : hxmc.I64)) return null;
		var c:Ptr = new Ptr(p);
		return hxmc.rt.Str.ofUtf8(c, hxmc.unsafe.LibC.strlen(c).toInt());
	}

	// (a typed C call given a handle of its invalid value: FnLower.typedCall)
	@:hxmc.unsafe @:hxmc.kernel public static function invalidHandle(v:Int, where:Ptr):Void {
		var r = report("hxmc: invalid handle ");
		r.int(v, 0);
		r.str(" passed to C");
		end(r, where);
	}

	@:hxmc.unsafe @:hxmc.kernel public static function badRange(pos:Int, len:Int, n:Int, where:Ptr):Void {
		var r = report("hxmc: span range ");
		r.int(pos, 0);
		r.str(" + ");
		r.int(len, 0);
		r.str(" out of range [0, ");
		r.int(n, 0);
		end(r, where);
	}

	@:hxmc.unsafe(gc) static inline function report(what:String):hxmc.rt.Os.Report {
		var r = new hxmc.rt.Os.Report(hxmc.unsafe.Mem.stack(hxmc.rt.Os.Report.BYTES));
		r.str(what);
		return r;
	}

	@:hxmc.unsafe @:hxmc.kernel static function end(r:hxmc.rt.Os.Report, where:Ptr) {
		r.str(") at ");
		r.cstr(where, 0, -1);
		r.ch(10);
		r.flush();
		hxmc.rt.Os.exit(2);
	}

	@:hxmc.unsafe @:hxmc.kernel public static function move(dst:Ptr, src:Ptr, bytes:hxmc.I64):Void
		hxmc.unsafe.LibC.memmove(dst, src, bytes);

	@:hxmc.unsafe @:hxmc.kernel public static function set(dst:Ptr, v:Int, bytes:hxmc.I64):Void
		hxmc.unsafe.LibC.memset(dst, v, bytes);
}
