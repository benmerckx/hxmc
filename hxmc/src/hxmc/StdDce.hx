package hxmc;

import core.TType;

// hxmc's std is DCE'd as the std it replaces. Programs see hxmc's std as a
// user class path (`-cp bin/hxmc/std`, given last so that its modules win),
// so Haxe's default DCE (`-dce std`) kept every class of it whole, as user
// code, where upstream's own module would be DCE'd field by field. A kept
// class's `__init__` runs, so live code then reached what nothing used:
// typing `haxe.Timer` (for the inline `stamp`) loads hxmc's
// `sys.thread.Thread`, kept whole, whose `events` reads `haxe.EventLoop`,
// which kept that class and its `__init__`, the main loop's set-up with the
// threads' callbacks (more than doubling a program printing
// `Timer.stamp()`). Every class and enum of hxmc's std, the runtime's too,
// gets `@:dce` after typing, the metadata that makes DCE treat a type
// outside the std as the std's (optimization/Dce.hx, keepWholeClass);
// `@:keep` still keeps one whole. hxmc's std is the class path holding
// `hxmc/rt/Runtime.hx`, as for macro.BundleFacts.
//
// The runtime's statics that generated code reaches by symbol alone (the
// @:hxmc.export, @:hxmc.host and @:hxmc.threadLocal ones Lower.findHosts
// binds: those of hxmc.ir.RuntimeSymbols and the others exported; of the
// classes of the target's runtime) are DCE's roots, @:keep; the rest of the runtime is kept, and its bodies typed
// (LazyStd), only when something reaches it.
class StdDce {
	static final ROOTS = [":hxmc.export", ":hxmc.host", ":hxmc.threadLocal"];

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
				// (the target, as Main.generate gives it to Lower: Lower.ofTarget)
				var abi = Abi.get(Options.read(com).target);
				hxmc.ir.Lower.targetOs = abi.osCode();
				hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
				hxmc.ir.Lower.targetPlatform = abi.platformCode();
				function ofStd(m:ModuleDef):Bool {
					var file = norm(core.Path.UniqueKey.lazyPath(m.mExtra.mFile));
					for (r in roots)
						if (StringTools.startsWith(file, r)) return true;
					return false;
				}
				function add(ml:core.Ast.Metadata, m:core.MetaList.StrictMeta):core.Ast.Metadata
					return core.Meta.has(m, ml) ? ml : core.ds.VectorTools.snoc(ml, new core.Ast.MetadataEntry(m, core.ds.VectorTools.vector(), core.Globals.nullPos));
				function root(cf:TClassField):Bool {
					for (m in ROOTS)
						if (hxmc.ir.Lower.hasMeta(m, cf.cfMeta)) return true;
					return false;
				}
				for (t in types)
					switch t {
						case TClassDecl(c) if (ofStd(c.clModule)):
							c.clMeta = add(c.clMeta, Dce);
							if (hxmc.ir.Lower.runtimeClass(c) && hxmc.ir.Lower.ofTarget(c))
								for (cf in c.clOrderedStatics)
									if (cf.cfMeta.length > 0 && root(cf)) cf.cfMeta = add(cf.cfMeta, Keep);
						case TEnumDecl(e) if (ofStd(e.eModule)): e.eMeta = add(e.eMeta, Dce);
						case _:
					}
			});
		}
	}
}
