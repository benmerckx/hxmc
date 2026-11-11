// Mem's and Atomic's intrinsics need @:hxmc.unsafe, also where no Ptr is in sight (but Mem's functions of values: KernelBits).
// expect: KernelMem.hx:7: KernelMem.frame: a call of hxmc.unsafe.Mem.frame (kernel: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.unsafe.*;

class KernelMem {
	@:hxmc.kernel static function frame():Bool
		return Mem.frame().isNull();

	static function main()
		trace(frame());
}
