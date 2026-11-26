class GraphCells {
	@:esm.hot.keyed
	public static function bump(?__hotId:String):Int {
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