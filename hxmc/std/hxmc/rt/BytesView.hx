package hxmc.rt;

import haxe.io.BytesData;
import hxmc.Span;
import hxmc.rt.Repr;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// haxe.io.BytesData's layout (hxmc.rt.Bytes: its length in its header, its
// bytes from offset 0) read for kernels, as StrView reads a string's: its
// bytes as a span as long as it, so every access past them is checked. They
// hold no references: a write needs no barrier.
@:keep @:hxmc.kernel @:hxmc.unsafe
class BytesView {
	public static function span(b:BytesData):Span<UInt8>
		return Span.unsafeOf((cast Mem.addr(b) : Ptr<UInt8>), b.length);

	// a haxe.io.Bytes' bytes (its data's, as long as it)
	public static function bytes(b:haxe.io.Bytes):Span<UInt8>
		return Span.unsafeOf((cast Bytes.bytes(b.getData()) : Ptr<UInt8>), b.length);

	// a BytesBuffer's length
	public static function bufLength(bb:Dynamic):Int
		return Repr.bbLen(bb);
}
