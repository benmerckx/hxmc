class KeyedSite {
	public static function bump():Int {
		@:esm.hot.cell var n = 0;
		return ++n;
	}

	public static function run():Int {
		var a = bump();
		var b = bump();
		return a * 10 + b;
	}
}