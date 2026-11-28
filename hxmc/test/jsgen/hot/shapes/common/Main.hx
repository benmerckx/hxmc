class Main {
	static function main() {
		var old = new Counter(1);
		var pet = new Pet();
		var red = Color.Red;
		js.Syntax.code("globalThis.tick = {0}", () -> {
			var fresh = new Counter(1);
			[
				"old " + old.describe(),
				"new " + fresh.describe(),
				"pet " + pet.speak() + "/" + new Pet().speak(),
				"color " + Colors.name(Colors.pick()) + " " + (red == Color.Red) + " " + Std.isOfType(red, Color),
				"meters " + (3 : Meters).show(),
				"tool " + Tools.helper(),
				"sub " + {
					var s = new Sub(1);
					s.describe() + " " + s.tag + " " + Std.isOfType(s, Sub);
				}
			].join(" | ");
		});
	}
}
