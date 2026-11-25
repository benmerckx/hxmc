class HotCell {
	@:esm.hot.function
	public static function tick():Int {
		@:esm.hot.cell var n = 0;
		return ++n;
	}
}