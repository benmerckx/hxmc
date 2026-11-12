package hxmc;

import haxe.io.Bytes;
import hxmc.Span.SpanData;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// A checked view of memory that cannot be written through (docs/interop.md,
// "Spans"): hxmc.Span's reading half, a distinct type (a Span converts to
// it, never back). It lives where a Span does: only in kernels, made by
// GC code only as an argument of a call of a kernel.
abstract ReadOnlySpan<T>(SpanData) {
	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	@:arrayAccess inline function get(i:Int):T
		return elem(i);

	extern function elem(i:Int):T;

	extern public function sub(pos:Int, len:Int):ReadOnlySpan<T>;

	// (Span.getI64)
	extern public function getI64(i:Int):hxmc.I64;

	extern public function getI32(i:Int):Int;

	extern public function reinterpret<U>():ReadOnlySpan<U>;

	// an atomic load of element i (Span.load)
	extern public function load(i:Int):T;

	// (hxmc.simd: 16, 8 or 4 bytes from byte pos * size(T), checked: op names
	// the load, v128.load, v128.load64_zero or v128.load32_zero)
	@:noCompletion extern public function vload(op:String, pos:Int):hxmc.simd.V128;

	extern public static function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):ReadOnlySpan<UInt8>;

	extern public static function ofIoBuffer(buf:IoBuffer, pos:Int = 0, len:Int = -1):ReadOnlySpan<UInt8>;

	extern public static function ofBuffer(buf:hxmc.Buffer, pos:Int = 0, len:Int = -1):ReadOnlySpan<UInt8>;

	// a call's argument: a value as a span of one, copied for the call (`const T *`)
	extern public static function of<T>(x:T):ReadOnlySpan<T>;

	// a call's argument in GC code: the elements of a (scalars or structs)
	// copied into C memory for the call: many structs from GC code
	extern public static function ofArray<T>(a:Array<T>):ReadOnlySpan<T>;

	extern public static function unsafeOf<T>(p:Ptr<T>, length:Int):ReadOnlySpan<T>;
}
