// An unchecked cast between anything but scalars needs @:hxmc.unsafe.
// expect: GcFreeCast.hx:15: GcFreeCast.wide: an unchecked cast from Small to Wide (gcfree: unchecked casts only between scalars)
@:hxmc.struct @:publicFields class Small {
	var a:Int;
	function new() {}
}

@:hxmc.struct @:publicFields class Wide {
	var a:Int;
	var b:Float;
}

class GcFreeCast {
	@:hxmc.gcfree static function wide(s:Small):Float {
		var w:Wide = cast s;
		return w.b;
	}

	static function main()
		trace(wide(new Small()));
}
