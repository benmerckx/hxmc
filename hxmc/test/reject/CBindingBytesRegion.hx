// A Bytes is lent only to a C call that enters no safe region: during a call that is not @:hxmc.fast, other threads collect and move it.
// expect: CBindingBytesRegion.hx:12: CBindingBytesRegion.main: a span over a Bytes passed to the C function slow_sum, which runs in a safe region (other threads collect meanwhile, and the Bytes may move) (kernel: a Bytes is lent only to a call that enters no region: lend an IoBuffer's, or declare the function @:hxmc.fast)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

@:hxmc.c extern class C {
	static function slow_sum(p:ReadOnlySpan<UInt8>):Int;
}

class CBindingBytesRegion {
	static function main()
		trace(C.slow_sum(ReadOnlySpan.ofBytes(haxe.io.Bytes.ofString("abc"))));
}
