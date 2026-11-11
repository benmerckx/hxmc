// A C function a safe kernel calls is declared @:hxmc.safe; a span parameter alone does not vouch for what C does with it.
// expect: CBindingNotSafe.hx:12: CBindingNotSafe.sum: a call of C.span_sum (kernel: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

@:hxmc.c @:hxmc.fast extern class C {
	static function span_sum(p:ReadOnlySpan<UInt8>):Int;
}

class CBindingNotSafe {
	@:hxmc.kernel static function sum(p:ReadOnlySpan<UInt8>):Int
		return C.span_sum(p);

	static function main()
		trace(sum(ReadOnlySpan.ofBytes(haxe.io.Bytes.ofString("abc"))));
}
