package context;

import core.Globals;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.Define;
import core.Timer;
import core.ds.Hashtbl;
import core.ds.NotFound;
import context.Common;
import compiler.hxb.HxbReader.dumpStats as hxbDumpStats;
import context.Parallel.ParallelArray;
import context.NativeLibraries.NativeLibrary;
import compiler.CompilationCache;
import compiler.hxb.HxbData;
import compiler.hxb.HxbWriterConfig;

// port: `lib` is the NativeLibrary interface.
class LibBuildTask extends ServerTask {
	final cs:Cache;
	final file:String;
	final ftime:Float;
	final lib:NativeLibrary<Dynamic, Dynamic>;

	public function new(cs:Cache, file:String, ftime:Float, lib:NativeLibrary<Dynamic, Dynamic>) {
		super(["build_lib", lib.getName()], 60);
		this.cs = cs;
		this.file = file;
		this.ftime = ftime;
		this.lib = lib;
	}

	function execute():Void {
		/* Created lookup and eagerly read each known type. */
		lib.load();
		var h = new Hashtbl<GlobalTypePath, Package>(0);
		for (path in lib.listModules()) {
			if (!h.mem(path)) {
				var p = Globals.filePos(file + " @ " + Globals.sTypePath(path));
				try {
					switch lib.build(path, p) {
						case null:
						case r:
							h.add(path, r);
					}
				} catch (_:Dynamic) {}
			}
		}
		lib.close();
		/* Save and set up lookup. */
		cs.addNativeLib(file, h, ftime);
	}
}

class CommonCache {
	public static function handleNativeLib(com:CommonContext, lib:NativeLibrary<Dynamic, Dynamic>):Void->Void {
		com.nativeLibs.allLibs.unshift(lib.getFilePath());
		function build(path:GlobalTypePath, p:Pos):Null<Package> {
			/* The first build has to load, afterwards we install a direct lib#build call. */
			lib.load();
			com.loadExternType = com.loadExternType.map(function(entry:context.Common.ExternTypeLoader):context.Common.ExternTypeLoader {
				return entry.name == lib.getFilePath() ? {name: entry.name, load: function(path, p) return lib.build(path, p)} : entry;
			});
			return lib.build(path, p);
		}
		com.loadExternType = com.loadExternType.concat([{name: lib.getFilePath(), load: build}]);
		if (!Define.rawDefined(com.defines, "haxe.noNativeLibsCache")) {
			var cs = com.cs;
			function init():Null<Hashtbl<GlobalTypePath, Package>> {
				var file = lib.getFilePath();
				var ftime = Common.fileTime(file);
				return switch cs.getNativeLib(file) {
					case lib if (lib != null && ftime <= lib.cNlMtime):
						/* Cached lib is good, set up lookup into cached files. */
						lib.cNlFiles;
					case _:
						/* Cached lib is outdated or doesn't exist yet, register build task. */
						cs.addTask(new LibBuildTask(cs, file, ftime, lib));
						null;
				}
			}
			return function() {
				var lut = init();
				switch lut {
					case null:
					case lut:
						function build(path:GlobalTypePath, p:Pos):Null<Package> {
							return lut.findOpt(path);
						}
						com.loadExternType = com.loadExternType.map(function(entry:context.Common.ExternTypeLoader):context.Common.ExternTypeLoader {
							return entry.name == lib.getFilePath() ? {name: entry.name, load: build} : entry;
						});
				}
			}
		} else
			/* Offline mode, just read library as usual. */
			return function() lib.load();
	}

	/* context */
	public static function getCache(com:CommonContext):ContextCache {
		return switch com.cache {
			case null:
				var sign = Define.getSignature(com.defines);
				com.cs.getContext(sign);
			case cache:
				cache;
		}
	}

	public static function getCacheSign(com:CommonContext):String {
		return switch com.cache {
			case null: Define.getSignature(com.defines);
			case cache: cache.getSign();
		}
	}

	public static function cacheContext(cs:Cache, com:CommonContext):Void {
		// port: (TypeBinding.typeLazyBodies)
		if (typing.TypeloadFields.TypeBinding.typeLazyBodies != null) typing.TypeloadFields.TypeBinding.typeLazyBodies(com);
		var cc = getCache(com);
		var sign = Define.getSignature(com.defines);

		var parallels:Array<{cc:ContextCache, m:ModuleDef, f:Void->CachedChunks}> = [];
		function cacheModule(m:ModuleDef) {
			if (Define.defined(com.defines, Define.DisableHxbCache)) {
				/* If we have a signature mismatch, look-up cache for module. Physical equality check is fine as a heuristic. */
				var cc = if (m.mExtra.mSign == sign) cc else cs.getContext(m.mExtra.mSign);
				cc.cacheModuleInMemory(m.mPath, m);
			} else {
				var anonIdentification = new typing.TanonIdentification<Dynamic>();
				function warn(w:core.Message.WarningCode, s:String, p:Pos):Void com.warning(w, com.warningOptions, s, p);
				var config:WriterTargetConfig = switch com.hxbWriterConfig {
					case null:
						new WriterTargetConfig(); // port: HxbWriterConfig.create_target_config ()
					case config:
						if (com.isMacroContext) config.macroConfig else config.targetConfig;
				}
				/* If we have a signature mismatch, look-up cache for module. Physical equality check is fine as a heuristic. */
				var cc = if (m.mExtra.mSign == sign) cc else cs.getContext(m.mExtra.mSign);
				switch cc.cacheHxbModule(config, warn, anonIdentification, m) {
					case null:
					case f:
						parallels.push({cc: cc, m: m, f: f});
				}
			}
		}
		for (m in com.modules) cacheModule(m);
		var a = Parallel.runWithPool(com.sctx.pool, function(pool) {
			return ParallelArray.map(pool, function(e:{cc:ContextCache, m:ModuleDef, f:Void->CachedChunks}) {
				var chunks = e.f();
				return {cc: e.cc, m: e.m, chunks: chunks};
			}, parallels, {cc: cc, m: TFunctions.nullModule, chunks: []});
		});
		for (e in a) {
			e.cc.addBinaryCache(e.m, e.chunks);
		}
		switch com.getMacros() {
			case null:
			case macroCom:
				cc.addChild(getCacheSign(macroCom));
				cacheContext(cs, macroCom);
		}
		if (Define.defined(com.defines, Define.HxbStats))
			hxbDumpStats(Globals.platformName(com.platform), com.hxbReaderStats);
	}

	public static function maybeAddContextSign(cs:Cache, com:CommonContext, desc:String):Void {
		var sign = Define.getSignature(com.defines);
		cs.addInfo(sign, desc, com.platform, com.classPaths, com.defines);
	}

	public static function lockSignature(com:CommonContext, name:String):Void {
		var cs = com.cs;
		maybeAddContextSign(cs, com, name);
		com.cache = getCache(com);
	}

	public static function maybeCacheContext(com:CommonContext):Void {
		if (com.display.dmsFullTyping && com.display.dmsPopulateCache) {
			Timer.time(com.timerCtx, ["server", "cache context"], function(com) {
				cacheContext(com.cs, com);
				return null;
			}, com);
			compiler.server.ServerMessage.cachedModules(com, "", com.modules.length);
		}
	}
}
