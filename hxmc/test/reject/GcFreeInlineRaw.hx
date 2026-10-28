// What Haxe inlines is checked as the caller's code: an inline helper over raw memory, even one declared @:hxmc.unsafe.
// expect: GcFreeInlineRaw.hx:12: GcFreeInlineRaw.f: a call of hxmc.unsafe.Mem.os (gcfree: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.unsafe.*;

class GcFreeInlineRaw {
	@:hxmc.unsafe static inline function platform():Int
		return Mem.os();

	@:hxmc.gcfree static function f(v:Int):Int {
		var x = v * 2;
		var y = x + 1;
		return y + platform();
	}

	static function main()
		trace(f(1) > 0);
}
