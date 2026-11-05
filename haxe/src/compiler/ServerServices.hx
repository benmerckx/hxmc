package compiler;

import haxe.display.Server.ContextParams;
import haxe.display.Server.ModuleParams;
import haxe.display.Server.ReadClassPathsParams;
import haxe.display.Server.SetCwdParams;
import haxe.display.Server.TypeParams;
import haxe.display.Protocol.FileParams;
import compiler.CompilationCache;
import compiler.CompilerInstance;
import compiler.DisplayServices;
import context.Common.CommonContext;
import core.Json.JsonValue;
import core.TFunctions.tInfos;

/** server/configure's parameters: the std's, with the print settings in their order (each
	is answered with a line, and an unknown name is an error) */
typedef ServerConfigureParams = {
	?noModuleChecks:Bool,
	?print:Array<{name:String, value:Bool}>
}

typedef GcCompactResult = {time:Float, before:Int, after:Int};

/** The server/* methods of the JSON-RPC protocol (and typer/compiledTypes), on the
	instance's cache: the std's parameters (haxe.display), the compiler's values. A
	ServiceError is the protocol's error response (an invalid directory, an unknown module);
	a failed compilation (the arguments) throws a CompilationError. The modules' and the
	memory's are Genjson's documents: they read the cache lazily as they are written. */
interface ServerApi {
	function resetCache():Void;
	function resetState():Void;
	function setCwd(p:SetCwdParams):Void;
	function gcCompact():GcCompactResult;

	/** after the init macros: the number of files the cache knows */
	function readClassPaths(p:ReadClassPathsParams):Null<Int>;

	/** the contexts that have a JSON description (the initialized ones) */
	function contexts():Array<ContextCache>;

	/** the paths of the context's modules (s_type_path) */
	function modules(p:ContextParams):Array<String>;

	function module(p:ModuleParams):JsonValue;
	function type(p:TypeParams):JsonValue;

	/** the contexts that have a type of the name in the module */
	function typeContexts(p:{modulePath:String, typeName:String}):Array<ContextCache>;

	/** the context's files, by key */
	function files(p:ContextParams):Array<CachedFile>;

	/** the full path of the file now known to be a module */
	function moduleCreated(p:FileParams):String;

	function invalidate(p:FileParams):Void;

	/** a line for each setting */
	function configure(p:ServerConfigureParams):Array<String>;

	function memory():JsonValue;
	function contextMemory(p:ContextParams):JsonValue;
	function moduleMemory(p:ModuleParams):JsonValue;

	/** after the filters: the compiled types (Genjson's) */
	function compiledTypes():Null<Array<JsonValue>>;
}

// port: not upstream: DisplayJson.handler's server/* methods, on a CompilerInstance's request
class ServerServices implements ServerApi {
	final instance:CompilerInstance;
	final env:Null<RequestEnv>;

	public function new(instance:CompilerInstance, ?env:RequestEnv) {
		this.instance = instance;
		this.env = env;
	}

	function now<T>(method:String, f:CommonContext->T):T
		return Services.answer(instance, env, method, com -> Answer(f(com)));

	public function resetCache():Void
		now("server/resetCache", function(com) {
			(com.cs : Cache).clear();
			context.display.DisplayJson.supportsResolve = false;
			context.display.DisplayException.reset();
			compiler.server.ServerConfig.reset();
			return null;
		});

	public function resetState():Void
		now("server/resetState", function(com) {
			com.sctx.persistentCwd = null;
			(com.cs : Cache).softClear();
			context.display.DisplayJson.supportsResolve = false;
			context.display.DisplayException.reset();
			compiler.server.ServerConfig.reset();
			return null;
		});

	public function setCwd(p:SetCwdParams):Void
		now("server/setCwd", function(com) {
			var dir = core.Path.getFullPath(p.dir);
			if (!(sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))) throw new ServiceError("Invalid directory: " + dir);
			com.sctx.persistentCwd = dir;
			return null;
		});

	public function gcCompact():GcCompactResult
		return now("server/gcCompact", function(_) {
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

	public function readClassPaths(p:ReadClassPathsParams):Null<Int>
		return Services.answer(instance, env, "server/readClassPaths", com -> After(AfterInitMacros, function() {
			var cs:Cache = com.cs;
			var cc = cs.getContext(core.Define.getSignature(com.defines));
			cc.setInitialized(true);
			context.display.DisplayToplevel.readClassPaths(com, ["init"]);
			if (p.wait == true) cs.runTasks(true, task -> task.getId()[0] == "explore");
			return cs.getFiles().length;
		}));

	public function contexts():Array<ContextCache>
		return now("server/contexts", com -> (com.cs : Cache).getContexts().filter(cc -> cc.getJson() != JNull));

	public function modules(p:ContextParams):Array<String>
		return now("server/modules", function(com) {
			var cc = (com.cs : Cache).getContext(p.signature);
			return cc.getHxb().fold(function(_, m:compiler.hxb.HxbData.ModuleCache, acc:Array<String>) {
				if (m.mcExtra.mKind != MFake) acc.unshift(core.Globals.sTypePath(m.mcPath));
				return acc;
			}, []);
		});

	public function module(p:ModuleParams):JsonValue
		return now("server/module", function(com) {
			var path = core.Ast.Ast.parsePath(p.path);
			var cc = (com.cs : Cache).getContext(p.signature);
			var typingMode:compiler.hxb.HxbData.TypingMode = if (core.Define.defined(com.defines,
				core.Define.DisableHxbOptimizations)) FullTyping else AllowPartialTyping;
			var find = context.display.DisplayJson.findModule.bind(typingMode, com, cc);
			return try core.json.Genjson.generateModule(cc.getHxb(), find, find(path)) catch (_:core.ds.NotFound) throw new ServiceError("No such module");
		});

	public function type(p:TypeParams):JsonValue
		return now("server/type", function(com) {
			var path = core.Ast.Ast.parsePath(p.modulePath);
			var cc = (com.cs : Cache).getContext(p.signature);
			try {
				var m = context.display.DisplayJson.findModule(FullTyping, com, cc, path);
				for (mt in m.mTypes) {
					switch mt {
						case TClassDecl(c): c.clRestore();
						case _:
					}
					if (tInfos(mt).mtPath.name == p.typeName) return core.json.Genjson.generateModuleType(core.json.Genjson.createFullConfig(), mt);
				}
			} catch (_:core.ds.NotFound) throw new ServiceError("No such module");
			throw new ServiceError("No such type");
		});

	public function typeContexts(p:{modulePath:String, typeName:String}):Array<ContextCache>
		return now("server/typeContexts", function(com) {
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

	public function files(p:ContextParams):Array<CachedFile>
		return now("server/files", function(com) {
			var cc = (com.cs : Cache).getContext(p.signature);
			var files = cc.getFiles().fold(function(file, cfile, acc:Array<{key:String, cfile:CachedFile}>) {
				acc.unshift({key: file, cfile: cfile});
				return acc;
			}, []);
			haxe.ds.ArraySort.sort(files, (a, b) -> context.display.Display.compareStrings(a.key, b.key));
			return files.map(f -> f.cfile);
		});

	public function moduleCreated(p:FileParams):String
		return now("server/moduleCreated", function(com) {
			var file = core.Path.getFullPath(p.file.toString());
			var key = com.partScope.fileKeys.get(file);
			for (cc in (com.cs : Cache).getContexts()) cc.getRemovedFiles().replace(key, {file: file, classPath: com.emptyClassPath});
			return file;
		});

	public function invalidate(p:FileParams):Void
		now("server/invalidate", function(com) {
			var fkey = com.partScope.fileKeys.get(p.file.toString());
			var cs:Cache = com.cs;
			cs.taintModules(fkey, ServerInvalidate);
			cs.removeFiles(fkey);
			return null;
		});

	public function configure(p:ServerConfigureParams):Array<String>
		return now("server/configure", function(_) {
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
		});

	public function memory():JsonValue
		return now("server/memory", com -> context.display.DisplayMemory.getMemoryJson(com.cs, MCache));

	public function contextMemory(p:ContextParams):JsonValue
		return now("server/memory/context", com -> context.display.DisplayMemory.getMemoryJson(com.cs, MContext(p.signature)));

	public function moduleMemory(p:ModuleParams):JsonValue
		return now("server/memory/module",
			com -> context.display.DisplayMemory.getMemoryJson(com.cs, MModule(p.signature, core.Ast.Ast.parsePath(p.path))));

	public function compiledTypes():Null<Array<JsonValue>>
		return Services.answer(instance, env, "typer/compiledTypes", com -> After(AfterFilters, function() {
			var ctx = core.json.Genjson.createFullConfig();
			return com.types.map(core.json.Genjson.generateModuleType.bind(ctx));
		}));
}
