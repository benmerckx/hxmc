class Main {
	static function main() {
		var c = new Counter();
		js.Syntax.code("globalThis.tick = {0}", () -> c.next());
	}
}
