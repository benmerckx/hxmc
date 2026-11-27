class StaticInitCycle {
	public static final first = new Access().readLast() ?? "first";

	static function main() {
		Sys.println(first);
		Sys.println(Last.value);
	}
}

private class Last {
	public static final value = new Access().readFirst() + ", last";
}

private class Access {
	public function new() {}

	public function readFirst():String
		return StaticInitCycle.first;

	public function readLast():String
		return Last.value;
}
