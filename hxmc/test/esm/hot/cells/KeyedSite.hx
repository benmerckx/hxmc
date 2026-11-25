// v2: insert call at top — ordinals shift; keyed cells reset (§13.11).
class KeyedSite {
	@:esm.hot.keyed
	public static function bump(?__hotId:String):Int {
		@:esm.hot.cell var n = 0;
		return ++n;
	}

	@:esm.hot.function
	public static function run():Int {
		bump();
		var a = bump();
		var b = bump();
		return a * 10 + b;
	}
}