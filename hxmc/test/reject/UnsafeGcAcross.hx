// @:hxmc.unsafe(gc) is trusted GC code: its raw heap addresses are still checked across GC points.
// expect: UnsafeGcAcross.hx:8: UnsafeGcAcross.poke: a raw heap address (Mem.addr) in p is live across the allocation of an array
import hxmc.unsafe.*;

class UnsafeGcAcross {
	static var keep:Array<Int>;

	@:hxmc.unsafe(gc) static function poke(b:haxe.io.Bytes) {
		var p = Mem.addr(b).add(8);
		keep = [1, 2, 3];
		Mem.setI32(p, 0, 5);
	}

	static function main()
		poke(haxe.io.Bytes.alloc(16));
}
