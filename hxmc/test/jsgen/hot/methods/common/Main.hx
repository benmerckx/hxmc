class Main {
	static function main() {
		var g = new Greeter("bob");
		var bound = g.greet;
		js.Syntax.code("globalThis.tick = {0}", () -> g.greet() + " | " + bound() + " | " + Greeter.shout("x") + " | " + Std.isOfType(g, Greeter));
	}
}
