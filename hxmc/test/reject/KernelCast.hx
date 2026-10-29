// An unchecked cast between anything but scalars needs @:hxmc.unsafe.
// expect: KernelCast.hx:15: KernelCast.wide: an unchecked cast from Small to Wide (kernel: unchecked casts only between scalars)
@:hxmc.struct @:publicFields class Small {
	var a:Int;
	function new() {}
}

@:hxmc.struct @:publicFields class Wide {
	var a:Int;
	var b:Float;
}

class KernelCast {
	@:hxmc.kernel static function wide(s:Small):Float {
		var w:Wide = cast s;
		return w.b;
	}

	static function main()
		trace(wide(new Small()));
}
