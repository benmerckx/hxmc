import staticinitsetup.Table;

class StaticInitSetup {
	static final value = new ReadTable().read();

	static function main() {
		Sys.println(value);
	}
}

private class ReadTable {
	public function new() {}
	public function read():String return Table.value;
}
