// js.Bundle.import loads the split files (bundled), so a program can replace it: here, to fail
// the first load, which the program retries (a browser's import() does not retry a failed load)
class Lazy {
	public static function hello() return "hello from a split";
}

class Loader {
	static var calls = 0;

	static function main() {
		var original = js.Bundle.importModule;
		js.Bundle.importModule = url -> {
			calls++;
			return calls == 1 ? js.lib.Promise.reject("first load fails") : original(url);
		}
		function load() return js.Bundle.split("lazy", () -> Lazy.hello());
		load().catchError(_ -> load()).then(v -> {
			trace(v);
			// (only a split build loads files, and es-modules not through js.Bundle.import: its splits are `import()`s, of
			// modules, here none: Lazy is the caller's)
			var mode = haxe.macro.Compiler.getDefine("hxmc.js");
			var split = mode != null && mode != "es-modules";
			trace("loads through js.Bundle.import: " + ((calls == 2) == split));
		});
	}
}
