// A vector's raw memory access (loadPtr) in a safe kernel needs @:hxmc.unsafe.
// expect: (kernel: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.simd.U8x16;
import hxmc.unsafe.Ptr;

class SimdPtrKernel {
	@:hxmc.kernel static function first(p:Ptr):Int
		return U8x16.loadPtr(p, 0).get(0);

	static function main()
		trace(first(hxmc.unsafe.IoBuffer.alloc(16).ptr));
}
