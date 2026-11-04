package hxmc.simd;

#if (target.name == "hxmc")
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Ref's raw memory accesses (the Mir interpreter): 16 bytes, or the low 8
// or 4 (v128.load64_zero, v128.store32_lane, ...)
@:hxmc.unsafe @:hxmc.kernel @:noCompletion class RefMem {
	static inline function bytes(op:Int):Int
		return op == 0x5a || op == 0x5c ? 4 : op == 0x5b || op == 0x5d ? 8 : 16;

	public static function load(op:Int, p:Ptr, off:Int):V128 {
		var n = bytes(op);
		return new V128(Mem.getI32(p, off), n > 4 ? Mem.getI32(p, off + 4) : 0, n > 8 ? Mem.getI32(p, off + 8) : 0, n > 8 ? Mem.getI32(p, off + 12) : 0);
	}

	public static function store(op:Int, p:Ptr, off:Int, v:V128):Void {
		var n = bytes(op);
		Mem.setI32(p, off, v.w0);
		if (n > 4) Mem.setI32(p, off + 4, v.w1);
		if (n > 8) {
			Mem.setI32(p, off + 8, v.w2);
			Mem.setI32(p, off + 12, v.w3);
		}
	}
}
#end
