// An inferred no-allocation function still observes movement in safe regions.
// target: linux-x86_64
// expect: RawAcrossRegion.borrow: a raw heap address (Mem.addr) in pointer is live across a call of the runtime's rt_blocking_enter
// expect: RawAcrossRegion.borrow: a raw heap address (Mem.addr) in pointer is live across a call of the runtime's rt_blocking_leave
import hxmc.unsafe.Blocking;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class RawAcrossRegion {
	static function borrow(value:Dynamic):Ptr {
		var pointer = Mem.addr(value);
		var region = Blocking.enter();
		Blocking.leave(region);
		return pointer;
	}

	static function main()
		Sys.println(borrow({value: 1}).isNull());
}
