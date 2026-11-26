@:build(EntryMacro.init())
class Main {
	@:esm.hot.function
	public static function view():Int {
		var _ = EntryMacro.xml(<span>{GraphCells.run()}</span>);
		return GraphCells.run();
	}

	static function main() {
		Reflect.field(GraphCells, "run");
		view();
	}
}