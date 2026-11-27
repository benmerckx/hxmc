// a module's names, apart from the modules it imports (es-modules: a binding is named apart from its own module's
// names only): the module's own `Thing`, beside another module's `Thing` it imports (aliased), one it imports for
// types only (TypeScript: named by its module), one a split loads (its import()'s binding aliased)
// ts output has: import { Thing as Thing$1 } from "./names/a/Thing.ts";
// ts output has: show(t: import("./names/b/Thing.ts").Thing)
// ts output has: ([{ Thing: Thing$2 }]) => Thing$2.name() + " " + Thing.name()
// ts: import { Names } from "./Names.ts";
// ts: const s: string = Names.all();
class Thing {
	public static function name() return "own";
}

class Named implements names.b.Thing {
	public function new() {}

	public function name() return "named";
}

class Names {
	static function show(t:names.b.Thing) return t.name();

	public static function all() return Thing.name() + " " + new names.a.Thing(1).name() + " " + show(new Named());

	static function main() {
		trace(all());
		js.Bundle.split("c", () -> names.c.Thing.name() + " " + Thing.name()).then(s -> trace(s));
	}
}
