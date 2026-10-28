// A type parameter's value is erased to a reference (boxed): no span through one, in kernels no type parameter at all.
// expect: SpanGeneric.hx:7: SpanGeneric.id: the parameter x has the GC type id.T (kernel: no GC values)
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
