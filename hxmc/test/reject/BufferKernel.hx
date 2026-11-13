// A Buffer is lent by GC code, as a call's argument: never from a kernel.
// expect: BufferKernel.sum: a span of a Buffer made in a kernel (kernel: GC code lends a Buffer, as a call's argument)
import hxmc.Buffer;
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class BufferKernel {
	@:hxmc.kernel static function first(s:ReadOnlySpan<UInt8>):Int
		return s.length > 0 ? s[0] : -1;

	@:hxmc.kernel static function sum(b:Buffer):Int
		return first(ReadOnlySpan.ofBuffer(b));

	static function main()
		trace(sum(new Buffer(4)));
}
