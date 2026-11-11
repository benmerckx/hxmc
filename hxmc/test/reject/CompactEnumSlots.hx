// A @:hxmc.compact enum's constructor has at most 32 slots (the collector's
// one word of its compact map), on every target.
// expect: Big.Many: @:hxmc.compact and 33 slots: at most 32
@:hxmc.compact
enum Big {
	Few(a:Big, n:Int);
	Many(f0:Float, f1:Float, f2:Float, f3:Float, f4:Float, f5:Float, f6:Float, f7:Float, f8:Float, f9:Float, f10:Float, f11:Float, f12:Float,
		f13:Float, f14:Float, f15:Float, f16:Float, f17:Float, f18:Float, f19:Float, f20:Float, f21:Float, f22:Float, f23:Float, f24:Float,
		f25:Float, f26:Float, f27:Float, f28:Float, f29:Float, f30:Float, f31:Float, b:Big);
}

class CompactEnumSlots {
	static function main()
		trace(Many(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, null));
}
