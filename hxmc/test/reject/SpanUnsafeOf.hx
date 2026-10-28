// Making a span from a raw address needs @:hxmc.unsafe: its owner vouches for it.
// expect: SpanUnsafeOf.hx:7: SpanUnsafeOf.make: the parameter p has the raw type hxmc.unsafe.Ptr<hxmc.unsafe.UInt8> (gcfree: raw memory needs @:hxmc.unsafe)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.*;

class SpanUnsafeOf {
	@:hxmc.gcfree static function make(p:Ptr<UInt8>, n:Int):Int
		return ReadOnlySpan.unsafeOf(p, n).length;

	static function main() {
		var buf = IoBuffer.alloc(4);
		trace(make(buf.ptr, 4));
		buf.free();
	}
}
