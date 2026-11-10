// A type parameter's value is erased to a reference (boxed): no span through one, as a kernel allocates no box.
// expect: SpanGeneric.hx:10: SpanGeneric.first is declared @:hxmc.kernel but reaches a GC point: it allocates an object
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanGeneric {
	@:hxmc.kernel static function id<T>(x:T):T
		return x;

	@:hxmc.kernel static function first(s:ReadOnlySpan<UInt8>):Int
		return id(s)[0];

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(first(ReadOnlySpan.ofBytes(b)));
	}
}
