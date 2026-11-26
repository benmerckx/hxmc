class HotCellFixed {
	public static function tick():Int {
		@:esm.hot.cell("app.counter") var n = 0;
		return ++n;
	}
}