package hxmc;

import haxe.io.Bytes;
import hxmc.Span.SpanData;
import hxmc.unsafe.UInt8;
#if macro
import haxe.macro.Expr;
#end

// hxmc.ReadOnlySpan on the targets other than hxmc: hxmc.Span's reading
// half over the same SpanData (Span.hx).
abstract ReadOnlySpan<T>(SpanData) {
	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	@:arrayAccess inline function get(i:Int):T
		return this.get(i);

	public inline function sub(pos:Int, len:Int):ReadOnlySpan<T>
		return cast this.sub(pos, len);

	public macro function reinterpret(self:Expr):Expr
		return SpanData.reinterpretOf(self);

	public inline function load(i:Int):T
		return this.load(i);

	public static inline function ofBytes(b:Bytes, pos:Int = 0, len:Int = -1):ReadOnlySpan<UInt8>
		return cast SpanData.ofBytes(b, pos, len);

	public static macro function ofIoBuffer(args:Array<Expr>):Expr
		return SpanData.hxmcOnly("ReadOnlySpan.ofIoBuffer");

	public static macro function unsafeOf(args:Array<Expr>):Expr
		return SpanData.hxmcOnly("ReadOnlySpan.unsafeOf");
}
