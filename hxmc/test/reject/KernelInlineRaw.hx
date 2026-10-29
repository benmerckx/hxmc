// What Haxe inlines is checked as the caller's code: an inline helper over raw memory, even one declared @:hxmc.unsafe.
// expect: KernelInlineRaw.hx:12: KernelInlineRaw.f: a call of hxmc.unsafe.Mem.os (kernel: Mem, Atomic and C functions need @:hxmc.unsafe)
import hxmc.unsafe.*;

class KernelInlineRaw {
	@:hxmc.unsafe static inline function platform():Int
		return Mem.os();

	@:hxmc.kernel static function f(v:Int):Int {
		var x = v * 2;
		var y = x + 1;
		return y + platform();
	}

	static function main()
		trace(f(1) > 0);
}
