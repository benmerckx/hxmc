package hxmc;

import core.TType;

// hxmc's std overrides are DCE'd as the std they replace. Programs see
// hxmc's std as a user class path (`-cp bin/hxmc/std`, given last so that
// its modules win), so Haxe's default DCE (`-dce std`) kept every class of
// an override whole, as user code, where upstream's own module would be
// DCE'd field by field. A kept class's `__init__` runs, so live code then
// reached what nothing used: typing `haxe.Timer` (for the inline `stamp`)
// loads hxmc's `sys.thread.Thread`, kept whole, whose `events` reads
// `haxe.EventLoop`, which kept that class and its `__init__`, the main
// loop's set-up with the threads' callbacks (more than doubling a program
// printing `Timer.stamp()`). Every class and enum of an override (the
// files of hxmc's std outside the `hxmc` package, the runtime's own) gets
// `@:dce` after typing, the metadata that makes DCE treat a type outside
// the std as the std's (optimization/Dce.hx, keepWholeClass); `@:keep`
// still keeps one whole. hxmc's std is the class path holding
// `hxmc/rt/Runtime.hx`, as for macro.BundleFacts.
class StdDce {
	public static function install() {
		var prev = compiler.Compiler.beforeTypingHook;
		compiler.Compiler.beforeTypingHook = function(com, actx) {
			if (prev != null) prev(com, actx);
			if (!com.platform.match(CustomTarget("hxmc"))) return;
			com.callbacks.addAfterTyping(types -> {
				function norm(path:String):String
					return haxe.io.Path.normalize(try sys.FileSystem.absolutePath(path) catch (_:Dynamic) path);
				var roots = [];
				for (cp in com.classPaths.asList())
					if (cp.path != "" && sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx"))
						roots.push(haxe.io.Path.addTrailingSlash(norm(cp.path)));
				if (roots.length == 0) return;
				function isOverride(m:ModuleDef):Bool {
					if (m.mPath.pack.length > 0 && m.mPath.pack[0] == "hxmc") return false;
					var file = norm(core.Path.UniqueKey.lazyPath(m.mExtra.mFile));
					for (r in roots)
						if (StringTools.startsWith(file, r)) return true;
					return false;
				}
				function mark(ml:core.Ast.Metadata) {
					if (!core.Meta.has(Dce, ml)) ml.push(new core.Ast.MetadataEntry(core.MetaList.StrictMeta.Dce, core.ds.VectorTools.vector(), core.Globals.nullPos));
				}
				for (t in types)
					switch t {
						case TClassDecl(c) if (isOverride(c.clModule)): mark(c.clMeta);
						case TEnumDecl(e) if (isOverride(e.eModule)): mark(e.eMeta);
						case _:
					}
			});
		}
	}
}
