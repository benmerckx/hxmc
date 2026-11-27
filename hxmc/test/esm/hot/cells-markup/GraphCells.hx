class GraphCells {
	public static function bump():Int {
		@:esm.hot.cell var n = 0;
		return ++n;
	}

	public static function run():Int {
		bump();
		return bump();
	}

	static function main() {
		run();
	}
}