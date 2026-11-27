import staticinitsetup.Table;

class StaticInitDispatchOrder {
	static final value = start();

	static function start():String {
		Sys.println("start");
		return read(new Good());
	}

	static function read(reader:Reader):String
		return reader.read();

	static function main() {
		Sys.println(value);
		Sys.println(read(new Late()));
	}
}

private interface Reader {
	function read():String;
}

private class Good implements Reader {
	public function new() {}
	public function read():String return "good";
}

private class Late implements Reader {
	public function new() {}
	public function read():String return Table.value;
}
