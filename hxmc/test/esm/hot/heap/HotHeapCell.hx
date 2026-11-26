class HotHeapCell {
	public static function bump():Int {
		@:esm.hot.cell var n = 0;
		return ++n;
	}
}