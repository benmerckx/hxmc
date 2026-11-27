// breakages found splitting a large program, each in its smallest form:
//  - an `__init__` that patches another type's methods must run before that type's file's code
//    binds them: the class goes into that file (or one above it) though only a split's code uses
//    it (a main type: main; a split's type, used by a split nested in it: that split's file)
//  - a type no code reaches (kept, found by reflection) whose interface only a split uses
//  - `trace` through a custom haxe.Log.trace, from a module of its own (modules: its import)
//  - a strict-mode word as a name, in a split's file (an ES module)
//  - a static whose initializer reaches a class of a later module through an interface's method (its
//    implementations: what it may run)
import regress.Interceptor;
import regress.Traced;

class Target {
	public function new() {}

	public function ring(n:Int) return "ring " + n;
}

interface Shape {
	function area():Int;
}

@:keep class Found implements Shape {
	public function new() {}

	public function area() return 6;
}

class Regressions {
	static function main() {
		haxe.Log.trace = (v, ?infos) -> js.Syntax.code("console.log({0})", "log: " + Std.string(v));
		trace(regress.Logging.Metrics.logger.name);
		var t = new Target();
		// (a closure: $bind, which keeps the method as it is now)
		var ring = t.ring;
		var shape:Dynamic = Type.createInstance(Type.resolveClass("Found"), []);
		js.Bundle.split("regress", () -> {
			Interceptor.count();
			trace(ring(1));
			trace(Std.isOfType(shape, Shape) + " " + (shape : Shape).area());
			Traced.hello();
			final late = new regress.Late();
			final lateRing = late.ring;
			// (the nested split's promise: its output comes before "done", split or not)
			return js.Bundle.split("regress-late", () -> {
				regress.Late.LateInterceptor.count();
				trace(lateRing(2));
				return Traced.twice(21);
			});
		}).then(v -> trace("done " + v));
	}
}
