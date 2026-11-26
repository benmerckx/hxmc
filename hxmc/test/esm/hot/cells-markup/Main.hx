@:build(EntryMacro.init())
class Main {
	public static function view():Int {
		var _ = EntryMacro.xml(<span>{GraphCells.run()}</span>);
		return GraphCells.run();
	}

	static function main() {
		Reflect.field(GraphCells, "run");
		view();
	}
}