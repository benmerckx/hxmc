package hxmc;

import haxe.io.Bytes;
import hxmc.Span.SpanData;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// A checked view of memory that cannot be written through (docs/interop.md,
// "Spans"): hxmc.Span's reading half, a distinct type (a Span converts to
// it, never back). It lives where a Span does: only in GC-free code, made by
// GC code only as an argument of a call of a GC-free function.
abstract ReadOnlySpan<T>(SpanData) {
	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	@:arrayAccess inline function get(i:Int):T
		return elem(i);

	extern function elem(i:Int):T;

	extern public function sub(pos:Int, len:Int):ReadOnlySpan<T>;

	extern public function reinterpret<U>():ReadOnlySpan<U>;

	extern public static function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):ReadOnlySpan<UInt8>;

	extern public static function ofIoBuffer(buf:IoBuffer, pos:Int = 0, len:Int = -1):ReadOnlySpan<UInt8>;

	extern public static function unsafeOf<T>(p:Ptr<T>, length:Int):ReadOnlySpan<T>;
}
