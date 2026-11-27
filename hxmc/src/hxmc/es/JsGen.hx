package hxmc.es;

// hxmc's JavaScript generator (docs/js.md), beside the port's (Genjs), for a program compiled with --js and
// -D hxmc.js=<mode>:
//   es          a main file, and a file per split point (js.Bundle.split, hxmc/portable/js/Bundle.hx), loaded when the
//               split is called
//   es-modules  an ES module per Haxe module
// A generator a macro sets (haxe.macro.Compiler.setCustomJSGenerator) comes after, and replaces it.
class JsGen {
	// the std's modules the generator has its own of (hxmc-es: js.Boot, Type, Reflect, Std), before the std's: beside
	// js.Bundle (hxmc/portable, MkStd's hxmc-portable), as the std has js/ and js/_std/
	static function overrideStd(com:context.Common.CommonContext) {
		var base = null;
		com.classPaths.iter(cp -> if (base == null && cp.path != "" && sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "js/Bundle.hx"))
			base = haxe.io.Path.addTrailingSlash(cp.path) + "hxmc-es/");
		if (base == null || !sys.FileSystem.exists(base))
			core.Error.abort("hxmc.js: hxmc's std for JavaScript (hxmc-es beside js/Bundle.hx) is not on the class path", core.Globals.nullPos);
		com.classPaths.add(new core.ClassPath.DirectoryClassPath(base + "_std/", StdTarget));
		com.classPaths.add(new core.ClassPath.DirectoryClassPath(base, StdTarget));
	}

	public static function install() {
		var prev = compiler.Compiler.beforeTypingHook;
		compiler.Compiler.beforeTypingHook = function(com, actx) {
			if (prev != null) prev(com, actx);
			if (!com.platform.match(Js)) return;
			var mode = core.Define.rawDefinedValueSafe(com.defines, "hxmc.js");
			if (mode == "") return;
			if (mode != "es" && mode != "es-modules")
				core.Error.abort("hxmc.js: unknown mode " + mode + " (es, es-modules)", core.Globals.nullPos);
			// (the std's `#if (js_es >= 6)` code, before typing)
			if (generators.Gctx.getEsVersion(com.defines) < 6)
				context.Common.defineValue(com, core.Define.JsEs, "6");
			overrideStd(com);
			// (an enum is a class)
			core.Define.rawUndefine(com.defines, "js_enums_as_arrays");
			// (TypeScript: the enum abstracts' values, as typing left them, before DCE removes the fields it inlined)
			com.callbacks.addAfterTyping(types -> Casts.recordEnums(types));
			com.jsGen = () -> Chunk.generate(context.Common.toGctx(com));
		}
	}
}
