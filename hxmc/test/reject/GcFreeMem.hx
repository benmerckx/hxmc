// Mem's and Atomic's intrinsics need @:hxmc.unsafe, also where no Ptr is in sight.
// expect: GcFreeMem.hx:7: GcFreeMem.os: a call of hxmc.unsafe.Mem.os (gcfree: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.unsafe.*;

class GcFreeMem {
	@:hxmc.gcfree static function os():Int
		return Mem.os();

	static function main()
		trace(os() >= 0);
}
