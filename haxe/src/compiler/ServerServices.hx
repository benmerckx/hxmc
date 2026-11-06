package compiler;

import haxe.display.Server.ContextParams;
import haxe.display.Server.ModuleParams;
import haxe.display.Server.ReadClassPathsParams;
import haxe.display.Server.SetCwdParams;
import haxe.display.Server.TypeParams;
import haxe.display.Protocol.FileParams;
import compiler.CompilationCache;
import compiler.CompilerInstance;
import context.Common.CommonContext;
import core.Json.JsonValue;
import core.TFunctions.tInfos;
import core.TType.ModuleType;

/** server/configure's parameters: the std's, with the print settings in their order (each
	is answered with a line, and an unknown name is an error) */
typedef ServerConfigureParams = {
	?noModuleChecks:Bool,
	?print:Array<{name:String, value:Bool}>
}

typedef GcCompactResult = {time:Float, before:Int, after:Int};

// port: not upstream: the server/* methods of the JSON-RPC protocol (and typer/compiledTypes)
// ... on a CompilerInstance's cache: the std's parameters (haxe.display), the compiler's
// ... values (DisplayJson encodes them). A ServiceError is the protocol's error response
// ... (an invalid directory, an unknown module); a failed compilation, a CompilationError.
class ServerServices {
	final instance:CompilerInstance;
	final env:Null<RequestEnv>;

	public function new(instance:CompilerInstance, ?env:RequestEnv) {
		this.instance = instance;
		this.env = env;
	}

	/** answered from the context, once the arguments are processed */
	function now<T>(f:CommonContext->T):T
		return instance.answer(com -> Answer(f(com)), env);

	public function resetCache():Void
		now(function(com) {
			(com.cs : Cache).clear();
			context.display.DisplayJson.supportsResolve = false;
			context.display.DisplayException.reset();
			compiler.server.ServerConfig.reset();
			return null;
		});

	public function resetState():Void
		now(function(com) {
			com.sctx.persistentCwd = null;
			(com.cs : Cache).softClear();
			context.display.DisplayJson.supportsResolve = false;
			context.display.DisplayException.reset();
			compiler.server.ServerConfig.reset();
			return null;
		});

	public function setCwd(p:SetCwdParams):Void
		now(function(com) {
			var dir = core.Path.getFullPath(p.dir);
			if (!(sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))) throw new ServiceError("Invalid directory: " + dir);
			com.sctx.persistentCwd = dir;
			return null;
		});

	public function gcCompact():GcCompactResult
		return now(function(_) {
			var t0 = Sys.time();
			#if hl
			var before = hl.Gc.stats().currentMemory;
			hl.Gc.major();
			var after = hl.Gc.stats().currentMemory;
			#else
			var before = 0., after = 0.;
			#end
			return {time: Sys.time() - t0, before: Std.int(before), after: Std.int(after)};
		});

	/** after the init macros: the number of files the cache knows */
	public function readClassPaths(p:ReadClassPathsParams):Null<Int>
		return instance.answer(com -> After(AfterInitMacros, function() {
			var cs:Cache = com.cs;
			var cc = cs.getContext(core.Define.getSignature(com.defines));
			cc.setInitialized(true);
			context.display.DisplayToplevel.readClassPaths(com, ["init"]);
			if (p.wait == true) cs.runTasks(true, task -> task.getId()[0] == "explore");
			return cs.getFiles().length;
		}), env);

	/** the contexts that have a JSON description (the initialized ones) */
	public function contexts():Array<ContextCache>
		return now(com -> (com.cs : Cache).getContexts().filter(cc -> cc.getJson() != JNull));

	/** the paths of the context's modules (s_type_path) */
	public function modules(p:ContextParams):Array<String>
		return now(function(com) {
			var cc = (com.cs : Cache).getContext(p.signature);
			return cc.getHxb().fold(function(_, m:compiler.hxb.HxbData.ModuleCache, acc:Array<String>) {
				if (m.mcExtra.mKind != MFake) acc.unshift(core.Globals.sTypePath(m.mcPath));
				return acc;
			}, []);
		});

	/** the cached module, with its dependencies' and dependents' signatures */
	public function module(p:ModuleParams):core.json.Genjson.ModuleSummary
		return now(function(com) {
			var path = core.Ast.Ast.parsePath(p.path);
			var cc = (com.cs : Cache).getContext(p.signature);
			var typingMode:compiler.hxb.HxbData.TypingMode = if (core.Define.defined(com.defines,
				core.Define.DisableHxbOptimizations)) FullTyping else AllowPartialTyping;
			var find = context.display.DisplayJson.findModule.bind(typingMode, com, cc);
			return try core.json.Genjson.summarizeModule(cc.getHxb(), find, find(path)) catch (_:core.ds.NotFound) throw new ServiceError("No such module");
		});

	/** the cached type (fully typed, read from the cache) */
	public function type(p:TypeParams):ModuleType
		return now(function(com) {
			var path = core.Ast.Ast.parsePath(p.modulePath);
			var cc = (com.cs : Cache).getContext(p.signature);
			try {
				var m = context.display.DisplayJson.findModule(FullTyping, com, cc, path);
				for (mt in m.mTypes) {
					switch mt {
						case TClassDecl(c): c.clRestore();
						case _:
					}
					if (tInfos(mt).mtPath.name == p.typeName) return mt;
				}
			} catch (_:core.ds.NotFound) throw new ServiceError("No such module");
			throw new ServiceError("No such type");
		});

	/** the contexts that have a type of the name in the module */
	public function typeContexts(p:{modulePath:String, typeName:String}):Array<ContextCache>
		return now(function(com) {
			var path = core.Ast.Ast.parsePath(p.modulePath);
			var acc = [];
			for (cc in (com.cs : Cache).getContexts()) {
				var m = cc.findModuleOpt(path);
				if (m == null) continue;
				for (mt in m.mTypes) {
					switch mt {
						case TClassDecl(c): c.clRestore();
						case _:
					}
					if (tInfos(mt).mtPath.name == p.typeName) {
						acc.unshift(cc);
						break;
					}
				}
			}
			return acc;
		});

	/** the context's files, by key */
	public function files(p:ContextParams):Array<CachedFile>
		return now(function(com) {
			var cc = (com.cs : Cache).getContext(p.signature);
			var files = cc.getFiles().fold(function(file, cfile, acc:Array<{key:String, cfile:CachedFile}>) {
				acc.unshift({key: file, cfile: cfile});
				return acc;
			}, []);
			haxe.ds.ArraySort.sort(files, (a, b) -> context.display.Display.compareStrings(a.key, b.key));
			return files.map(f -> f.cfile);
		});

	/** the full path of the file now known to be a module */
	public function moduleCreated(p:FileParams):String
		return now(function(com) {
			var file = core.Path.getFullPath(p.file.toString());
			var key = com.partScope.fileKeys.get(file);
			for (cc in (com.cs : Cache).getContexts()) cc.getRemovedFiles().replace(key, {file: file, classPath: com.emptyClassPath});
			return file;
		});

	public function invalidate(p:FileParams):Void
		now(function(com) {
			var fkey = com.partScope.fileKeys.get(p.file.toString());
			var cs:Cache = com.cs;
			cs.taintModules(fkey, ServerInvalidate);
			cs.removeFiles(fkey);
			return null;
		});

	/** a line for each setting */
	public function configure(p:ServerConfigureParams):Array<String>
		return now(_ -> applyConfigure(p));

	/** server/configure's effect (the settings are the process's): a line for each setting */
	public static function applyConfigure(p:ServerConfigureParams):Array<String> {
		var l = (p.print == null ? [] : p.print).map(function(f) {
			try {
				compiler.server.ServerMessage.setByName(f.name, f.value);
			} catch (_:core.ds.NotFound) {
				throw new ServiceError("Invalid print parame name: " + f.name);
			}
			return 'Printing ${f.name} ' + (f.value ? "enabled" : "disabled");
		});
		if (p.noModuleChecks != null) {
			compiler.server.ServerConfig.doNotCheckModules = p.noModuleChecks;
			l.unshift("Module checks " + (p.noModuleChecks ? "disabled" : "enabled"));
		}
		return l;
	}

	public function memory():context.display.DisplayMemory.CacheMemory
		return now(com -> context.display.DisplayMemory.cacheMemory(com.cs));

	public function contextMemory(p:ContextParams):context.display.DisplayMemory.ContextMemory
		return now(com -> context.display.DisplayMemory.contextMemory(com.cs, p.signature));

	public function moduleMemory(p:ModuleParams):context.display.DisplayMemory.ModuleMemoryReport
		return now(com -> context.display.DisplayMemory.moduleMemory(com.cs, p.signature, core.Ast.Ast.parsePath(p.path)));

	/** after the filters: the compiled types */
	public function compiledTypes():Null<Array<ModuleType>>
		return instance.answer(com -> After(AfterFilters, () -> com.types.copy()), env);
}
