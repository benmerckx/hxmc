// A caller also needs the check when its no-allocation callee enters a region.
// target: linux-x86_64
// expect: RawAcrossBlockingCall.borrow: a raw heap address (Mem.addr) in pointer is live across a call of RawAcrossBlockingCall.region
import hxmc.unsafe.Blocking;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class RawAcrossBlockingCall {
	static function region():Void {
		var state = Blocking.enter();
		Blocking.leave(state);
	}

	static function borrow(value:Dynamic):Ptr {
		var pointer = Mem.addr(value);
		region();
		return pointer;
	}

	static function main()
		Sys.println(borrow({value: 1}).isNull());
}
