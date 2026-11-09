import hxmc.unsafe.Blocking;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class RawNoGc {
	static function address(value:Dynamic):Ptr {
		var pointer = Mem.addr(value);
		return pointer;
	}

	@:hxmc.unsafe static function trusted(value:Dynamic):Ptr {
		var pointer = Mem.addr(value);
		var region = Blocking.enter();
		Blocking.leave(region);
		return pointer;
	}

	static function main() {
		var value = {value: 1};
		Sys.println(address(value).isNull());
		// Keep the explicit unsafe escape hatch reachable for compilation;
		// the corpus supplies no arguments and does not execute that branch.
		if (Sys.args().length > 0) Sys.println(trusted(value).isNull());
	}
}
