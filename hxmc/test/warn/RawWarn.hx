// Raw memory outside @:hxmc.unsafe code is a warning in a program's own code
// (-D hxmc.strict: an error), naming the function and its first raw use. A
// trusted inline helper is trusted where it lands; scalars' C calls are not raw;
// an unmarked coroutine's state machine is checked (CoroUnsafe: a marked one's not).
// warns: RawWarn.peek: a call of hxmc.unsafe.Mem.getI32 (raw memory needs @:hxmc.unsafe)
// warns: RawWarn.main: the local p of the raw type hxmc.unsafe.Ptr<Void> and 1 more (raw memory needs @:hxmc.unsafe)
// warns: unmarked.invokeResume: the local p of the raw type hxmc.unsafe.Ptr<Void>
import hxmc.unsafe.*;

class RawWarn {
	static function peek(o:Dynamic):Int
		return Mem.getI32(Mem.addr(o), 0);

	// trusted, and it allocates
	@:hxmc.unsafe(gc) static function scratch(n:Int):Int {
		var p = LibC.malloc(n);
		LibC.free(p);
		return [n].length;
	}

	// a coroutine without the mark: its state machine checked as any code
	@:coroutine static function unmarked():Int {
		var p = LibC.malloc(4);
		LibC.free(p);
		return 0;
	}

	@:hxmc.unsafe static inline function units(s:String):Int
		return Mem.getI32(Mem.addr(s), 0);

	static function main() {
		var p = LibC.malloc(8);
		LibC.free(p);
		trace(peek("x") + scratch(4) + units("abc") + LibC.rand() * 0 + (hxmc.Platform.os() >= 0 ? 1 : 0));
	}
}
