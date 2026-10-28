// Mem's and Atomic's intrinsics need @:hxmc.unsafe, also where no Ptr is in sight.
// expect: KernelMem.hx:7: KernelMem.os: a call of hxmc.unsafe.Mem.os (kernel: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.unsafe.*;

class KernelMem {
	@:hxmc.kernel static function os():Int
		return Mem.os();

	static function main()
		trace(os() >= 0);
}
