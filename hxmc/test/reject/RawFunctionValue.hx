// A raw function as a value is raw: called through a local, it is no call of Mem.
// define: hxmc.strict
// expect: RawFunctionValue.hx:17: characters 13-30
// expect: RawFunctionValue.main: the function hxmc.unsafe.Mem.setRefBarrier as a value and 2 more (raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.Atomic;
import hxmc.unsafe.Mem;

class Box {
	public var a = 1;

	public function new() {}
}

class RawFunctionValue {
	static function main() {
		var o = new Box();
		var set = Mem.setRefBarrier, tag = Mem.untagDynamic, add = Atomic.add32;
		set(o, 4096, o);
		trace(tag(haxe.Int64.make(0, 0x1234560)), add, o.a);
	}
}
