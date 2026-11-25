package js;

// Code splitting for hxmc's JavaScript generator (-D hxmc.js=es,
// docs/js.md): `Bundle.split(name, () -> ...)` runs its initializer once a
// separate file of the output, holding the initializer and the types only it
// needs, is loaded. The initializer may capture `this` and locals that never
// change, so that a program behaves the same whether it is split or not: with
// another generator, this implementation runs the initializer itself, a
// microtask later, as the loaded file would.
// With -D hxmc.js=es-modules a split is no file: its call imports the modules its
// initializer needs (`import()`, of their paths, which a bundler follows), and `base` and
// `importModule` are not used: what loads the modules loads these (docs/plans/esgen.md).
class Bundle {
	static final p:js.lib.Promise<Int> = js.lib.Promise.resolve(42);

	// the address the files of splits are loaded relative to, when set
	// (default: the main file's, or -D hxmc.js.chunk-base=<expression>)
	public static var base:Null<String> = null;

	// loads the file of a split, by its absolute address, as an ES module: `import()` (named so
	// in the output; `import` is a keyword of Haxe). A program may replace it, e.g. to retry a
	// failed load, which a browser's `import()` does not.
	@:keep @:native("import") public static dynamic function importModule(url:String):js.lib.Promise<Dynamic>
		return js.Syntax.code("import({0})", url);

	public static function split<T>(name:String, init:() -> T):js.lib.Promise<T> {
		return p.then(_ -> init());
	}
}
