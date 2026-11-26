class KeyedMultiCell {
	public static function bump():Int {
		@:esm.hot.cell var n = 0;
		@:esm.hot.cell var m = 0;
		return (++n) * 10 + (++m);
	}

	public static function run():Int {
		var a = bump();
		var b = bump();
		return a + b;
	}
}