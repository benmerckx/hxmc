class Main {
	static function main() {
		var d = new Derived(7);
		var p = new Props();
		js.Syntax.code("globalThis.tick = {0}", () -> {
			p.x = p.x + 1;
			d.describe() + " | " + p.x + " | " + Use.both() + " | " + Use.color(Use.pick()) + " | " + (Reflect.field(d, "old") != null);
		});
	}
}
