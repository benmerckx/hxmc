package compiler;

import core.Ast;
import core.ClassPaths.ResolvedFile;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.Json;
import core.TType;
import core.ds.Hashtbl;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import core.ds.NotFound;
import core.ds.PriorityQueue;
import compiler.hxb.HxbData;
import compiler.hxb.HxbWriter;
import syntax.Parser.ParserDisplayInformation;
import core.ds.VectorTools.vector;

// port: Digest.t signatures are hexadecimal strings (see Define.getSignature).
@:structInit class CachedFile {
	public var cFilePath:ResolvedFile;
	public var cTime:Float;
	public var cPackage:Array<String>;
	public var cDecls:haxe.ds.Vector<TypeDecl>;
	public var cModuleName:Null<String>;
	public var cPdi:ParserDisplayInformation;

	public inline function new(cFilePath:ResolvedFile, cTime:Float, cPackage:Array<String>, cDecls:haxe.ds.Vector<TypeDecl>,
			cModuleName:Null<String>, cPdi:ParserDisplayInformation) {
		this.cFilePath = cFilePath;
		this.cTime = cTime;
		this.cPackage = cPackage;
		this.cDecls = cDecls;
		this.cModuleName = cModuleName;
		this.cPdi = cPdi;
	}
}

@:structInit class CachedDirectory {
	public var cPath:String;
	public var cMtime:Float;

	public inline function new(cPath:String, cMtime:Float) {
		this.cPath = cPath;
		this.cMtime = cMtime;
	}
}

@:structInit class CachedNativeLib {
	public var cNlMtime:Float;
	public var cNlFiles:Hashtbl<GlobalTypePath, Package>;

	public inline function new(cNlMtime:Float, cNlFiles:Hashtbl<GlobalTypePath, Package>) {
		this.cNlMtime = cNlMtime;
		this.cNlFiles = cNlFiles;
	}
}

typedef HaxelibKey = {libs:Array<String>, cwd:Null<String>};

class CompilationCache {
	public static function getModuleNameOfCfile(file:String, cfile:CachedFile):String {
		return switch cfile.cModuleName {
			case null:
				var name = core.Path.moduleNameOfFile(file);
				cfile.cModuleName = name;
				name;
			case name:
				name;
		}
	}

	// port: tables whose iteration order shows in display/server output are OcamlHashtbl
	// with OCaml's polymorphic hash, so they iterate like upstream's Hashtbl.
	public static function stringTable<V>():OcamlHashtbl<String, V> return new OcamlHashtbl(OcamlHash.hashString, (a, b) -> a == b, 0);

	public static function pathTable<V>():OcamlHashtbl<GlobalTypePath, V> return new OcamlHashtbl(OcamlHash.hashPath, pathEq, 0);

	// port: OCaml structural equality on type paths.
	public static function pathEq(a:GlobalTypePath,
			b:GlobalTypePath):Bool return a.name == b.name && a.pack.length == b.pack.length && a.pack.join(".") == b.pack.join(".");

	public static function createDirectory(path:String, mtime:Float):CachedDirectory {
		return {cPath: path, cMtime: mtime};
	}
}

class ContextCache {
	final index:Int;
	final sign:String;
	final files:OcamlHashtbl<String, CachedFile> = CompilationCache.stringTable();
	final modules:OcamlHashtbl<GlobalTypePath, ModuleDef> = CompilationCache.pathTable();
	final binaryCache:OcamlHashtbl<GlobalTypePath, ModuleCache> = CompilationCache.pathTable();
	final fakeModules:OcamlHashtbl<String, ModuleDef> = CompilationCache.stringTable();
	final tmpBinaryCache:OcamlHashtbl<GlobalTypePath, ModuleCache> = CompilationCache.pathTable();
	final getHxbModuleMutex = new sys.thread.Mutex();
	final removedFiles:OcamlHashtbl<String, ResolvedFile> = CompilationCache.stringTable();
	var json:JsonValue = JNull;
	var initialized = false;
	var lastAccessTime = Sys.time();
	final children:OcamlHashtbl<String, Bool> = CompilationCache.stringTable();

	public function new(index:Int, sign:String) {
		this.index = index;
		this.sign = sign;
	}

	/* files */
	public function findFile(key:String):CachedFile {
		return files.find(key);
	}

	public function cacheFile(key:String, path:ResolvedFile, time:Float, data:Package, pdi:ParserDisplayInformation):Void {
		files.replace(key, {
			cFilePath: path,
			cTime: time,
			cPackage: data.pack,
			cDecls: data.declarations,
			cModuleName: null,
			cPdi: pdi
		});
	}

	public function removeFile(key:String):Void {
		try {
			var f = files.find(key);
			files.remove(key);
			removedFiles.replace(key, f.cFilePath);
		} catch (_:NotFound) {}
	}

	// Like remove_file, but doesn't keep track of the file
	public function removeFileForReal(key:String):Void {
		files.remove(key);
	}

	/* modules */
	public function findModule(path:GlobalTypePath):ModuleDef {
		return modules.find(path);
	}

	public function findModuleOpt(path:GlobalTypePath):Null<ModuleDef> {
		return modules.findOpt(path);
	}

	public function getHxbModule(path:GlobalTypePath):ModuleCache {
		getHxbModuleMutex.acquire();
		try {
			var result = try {
				tmpBinaryCache.find(path);
			} catch (_:NotFound) {
				var mc = binaryCache.find(path);
				var mExtra = mc.mcExtra.clone(); // port: { mc.mc_extra with m_deps = mc.mc_extra.m_deps }
				mExtra.mDeps = mc.mcExtra.mDeps.copy(); // port: m_deps is a persistent map upstream
				var mc:ModuleCache = {
					mcPath: mc.mcPath,
					mcId: mc.mcId,
					mcChunks: mc.mcChunks,
					mcExtra: mExtra
				};
				tmpBinaryCache.add(path, mc);
				mc;
			}
			getHxbModuleMutex.release();
			return result;
		} catch (e:Dynamic) {
			getHxbModuleMutex.release();
			throw e;
		}
	}

	public function findModuleExtra(path:GlobalTypePath):ModuleDefExtra {
		return try modules.find(path).mExtra catch (_:NotFound) getHxbModule(path).mcExtra;
	}

	public function addBinaryCache(m:ModuleDef, chunks:CachedChunks):Void {
		var mExtra = m.mExtra.clone();
		mExtra.mDeps = m.mExtra.mDeps.copy(); // port: m_deps is a persistent map upstream
		mExtra.mCacheState = MSGood;
		mExtra.mDisplayDeps = null;
		binaryCache.replace(m.mPath, {
			mcPath: m.mPath,
			mcId: m.mId,
			mcChunks: chunks,
			mcExtra: mExtra
		});
	}

	public function cacheHxbModule(config:compiler.hxb.HxbWriterConfig.WriterTargetConfig,
			warn:core.Message.WarningCode->String->core.Globals.Pos->Void, anonIdentification:typing.TanonIdentification<Dynamic>,
			m:ModuleDef):Null<Void->CachedChunks> {
		return switch m.mExtra.mKind {
			case MImport:
				modules.add(m.mPath, m);
				null;
			case _:
				function() {
					var writer = new HxbWriter(config, warn, anonIdentification);
					writer.writeModule(m);
					return (writer.getChunks() : CachedChunks);
				}
		}
	}

	public function cacheModuleInMemory(path:GlobalTypePath, m:ModuleDef):Void {
		modules.replace(path, m);
	}

	/* fake modules */

	public function findFakeModule(key:String):ModuleDef {
		return fakeModules.find(key);
	}

	public function addFakeModule(key:String, m:ModuleDef):Void {
		fakeModules.replace(key, m);
	}

	public function removeFakeModule(key:String):Void {
		fakeModules.remove(key);
	}

	public function clearTempCache():Void {
		tmpBinaryCache.clear();
	}

	public function clearCache():Void {
		modules.clear();
		clearTempCache();
	}

	// Clears all module caches and user-file parse cache entries, preserving only stdlib/lib file parse cache.
	public function clearModules():Void {
		modules.clear();
		binaryCache.clear();
		fakeModules.clear();
		clearTempCache();
		removedFiles.clear();
		var removed = files.fold(function(key, cfile:CachedFile, acc:Array<String>) {
			switch cfile.cFilePath.classPath.scope {
				case User:
					acc.push(key);
				case Std | StdTarget | Lib:
			}
			return acc;
		}, []);
		for (key in removed) files.remove(key);
	}

	/* initialization */
	public function isInitialized():Bool return initialized;

	public function setInitialized(value:Bool):Void initialized = value;

	public function getSign():String return sign;

	public function getIndex():Int return index;

	public function getFiles():OcamlHashtbl<String, CachedFile> return files;

	public function getModules():OcamlHashtbl<GlobalTypePath, ModuleDef> return modules;

	public function getHxb():OcamlHashtbl<GlobalTypePath, ModuleCache> return binaryCache;

	/* TODO handle hxb cache there too */
	public function getRemovedFiles():OcamlHashtbl<String, ResolvedFile> return removedFiles;

	public function getJson():JsonValue return json;

	public function setJson(j:JsonValue):Void json = j;

	/* Pointers for memory inspection. */
	public function getPointers():haxe.ds.Vector<Dynamic> return vector(files, modules, binaryCache);

	/* access tracking */
	public function updateAccessTime():Void lastAccessTime = Sys.time();

	public function getLastAccessTime():Float return lastAccessTime;

	/* child contexts */
	public function addChild(childSign:String):Void children.replace(childSign, true);

	public function getChildren():OcamlHashtbl<String, Bool> return children;
}

abstract class ServerTask {
	final id:Array<String>;
	final priority:Int;

	public function new(id:Array<String>, priority:Int) {
		this.id = id;
		this.priority = priority;
	}

	abstract function execute():Void;

	public function run():Void {
		execute();
	}

	public function getPriority():Int return priority;

	public function getId():Array<String> return id;
}

class ArbitraryTask extends ServerTask {
	final f:Void->Void;

	public function new(id:Array<String>, priority:Int, f:Void->Void) {
		super(id, priority);
		this.f = f;
	}

	function execute():Void {
		f();
	}
}

class Cache {
	final contexts:OcamlHashtbl<String, ContextCache> = CompilationCache.stringTable();
	var contextList:Array<ContextCache> = [];
	final haxelib:Hashtbl<HaxelibKey, Array<String>> = new Hashtbl(0);
	final directories:OcamlHashtbl<String, Array<CachedDirectory>> = CompilationCache.stringTable();
	final nativeLibs:Hashtbl<String, CachedNativeLib> = new Hashtbl(0);
	var tasks:PriorityQueue<ServerTask> = Empty;

	public function new() {}

	public function clear():Void {
		contexts.clear();
		contextList = [];
		haxelib.clear();
		directories.clear();
		nativeLibs.clear();
		tasks = Empty;
	}

	// Like clear, but preserves the file parse cache and directory cache within each context.
	public function softClear():Void {
		contexts.iter((_, cc) -> cc.clearModules());
		contextList = [];
		haxelib.clear();
		nativeLibs.clear();
		tasks = Empty;
	}

	/* contexts */
	public function clearTempCache():Void {
		contexts.iter((_, ctx) -> ctx.clearTempCache());
	}

	function contextCount():Int {
		return contexts.fold((_, _, n) -> n + 1, 0);
	}

	public function getContext(sign:String):ContextCache {
		try {
			var cache = contexts.find(sign);
			cache.updateAccessTime();
			if (contextList.indexOf(cache) < 0)
				contextList.unshift(cache);
			return cache;
		} catch (_:NotFound) {
			var cache = new ContextCache(contextCount(), sign);
			cache.updateAccessTime();
			contextList.unshift(cache);
			contexts.add(sign, cache);
			return cache;
		}
	}

	public function addInfo(sign:String, desc:String, platform:core.Globals.Platform, classPaths:core.ClassPaths,
			defines:core.Define.DefineContext):Int {
		var cc = getContext(sign);
		// port: PMap.foldi with a cons accumulator: descending key order
		var keys = [for (k in defines.values.keys()) k];
		keys.sort(core.ds.Key.compareStrings);
		keys.reverse();
		var jo = JObject([
			{name: "index", value: JInt(cc.getIndex())},
			{name: "desc", value: JString(desc)},
			{name: "platform", value: JString(Globals.platformName(platform))},
			{name: "classPaths", value: JArray(classPaths.asStringList().map(s -> JString(s)))},
			{name: "signature", value: JString(sign)},
			{
				name: "defines",
				value: JArray([
					for (k in keys) JObject([
						{name: "key", value: JString(k)},
						{name: "value", value: JString(defines.values.get(k))}
					])
				])
			}
		]);
		cc.setJson(jo);
		return cc.getIndex();
	}

	public function getContexts():Array<ContextCache> return contextList;

	/* files */
	public function removeFiles(file:String):Void {
		contexts.iter((_, cc) -> cc.removeFile(file));
	}

	public function getContextFiles(signs:Array<String>):Array<{file:String, cfile:CachedFile}> {
		return contexts.fold(function(sign, cc, acc:Array<{file:String, cfile:CachedFile}>) {
			if (signs.indexOf(sign) >= 0) return cc.getFiles().fold(function(file, cfile, acc:Array<{file:String, cfile:CachedFile}>) {
				acc.unshift({file: file, cfile: cfile});
				return acc;
			}, acc);
			else return acc;
		}, []);
	}

	public function getFiles():Array<{sign:String, file:String, cfile:CachedFile}> {
		return contexts.fold(function(sign, cc, acc:Array<{sign:String, file:String, cfile:CachedFile}>) {
			return cc.getFiles().fold(function(file, cfile, acc:Array<{sign:String, file:String, cfile:CachedFile}>) {
				acc.unshift({sign: sign, file: file, cfile: cfile});
				return acc;
			}, acc);
		}, []);
	}

	/* modules */
	public function iterModules(f:ModuleDef->Void):Void {
		contexts.iter(function(_, cc) {
			cc.getModules().iter(function(_, m) {
				f(m);
			});
		});
	}

	public function getModules():Array<ModuleDef> {
		return contexts.fold(function(_, cc, acc:Array<ModuleDef>) {
			return cc.getModules().fold(function(_, m, acc:Array<ModuleDef>) {
				acc.unshift(m);
				return acc;
			}, acc);
		}, []);
	}

	public function taintModule(mPath:GlobalTypePath, reason:ModuleTaintingReason):Void {
		contexts.iter(function(_, cc) {
			cc.getModules().iter(function(_, m) {
				if (core.ds.Key.compare(m.mPath, mPath) == 0) m.mExtra.mCacheState = MSBad(Tainted(reason));
			});
			cc.getHxb().iter(function(_, mc) {
				if (core.ds.Key.compare(mc.mcPath, mPath) == 0)
					mc.mcExtra.mCacheState = switch [reason, mc.mcExtra.mCacheState] {
						case [CheckDisplayFile, state = MSBad(_)]: state;
						case _: MSBad(Tainted(reason));
					}
			});
		});
	}

	public function taintModules(fileKey:String, reason:ModuleTaintingReason):Void {
		contexts.iter(function(_, cc) {
			cc.getModules().iter(function(_, m) {
				if (core.Path.UniqueKey.lazyKey(m.mExtra.mFile) == fileKey) m.mExtra.mCacheState = MSBad(Tainted(reason));
			});
			cc.getHxb().iter(function(_, mc) {
				if (core.Path.UniqueKey.lazyKey(mc.mcExtra.mFile) == fileKey)
					mc.mcExtra.mCacheState = switch [reason, mc.mcExtra.mCacheState] {
						case [CheckDisplayFile, state = MSBad(_)]: state;
						case _: MSBad(Tainted(reason));
					}
			});
		});
	}

	/* haxelibs */
	public function findHaxelib(key:HaxelibKey):Array<String> {
		return haxelib.find(key);
	}

	public function cacheHaxelib(key:HaxelibKey, value:Array<String>):Void {
		haxelib.replace(key, value);
	}

	/* directories */
	public function findDirectories(key:String):Array<CachedDirectory> {
		return directories.find(key);
	}

	public function addDirectories(key:String, value:Array<CachedDirectory>):Void {
		directories.replace(key, value);
	}

	public function removeDirectory(key:String, value:String):Void {
		try {
			var current = findDirectories(key);
			directories.replace(key, current.filter(dir -> dir.cPath != value));
		} catch (_:NotFound) {}
	}

	public function hasDirectory(key:String, value:String):Bool {
		return try Lambda.exists(findDirectories(key), dir -> dir.cPath == value) catch (_:NotFound) false;
	}

	public function addDirectory(key:String, value:CachedDirectory):Void {
		try {
			var current = findDirectories(key);
			addDirectories(key, [value].concat(current));
		} catch (_:NotFound) {
			addDirectories(key, [value]);
		}
	}

	public function clearDirectories(key:String):Void {
		directories.remove(key);
	}

	/* native lib */
	public function addNativeLib(key:String, files:Hashtbl<GlobalTypePath, Package>, timestamp:Float):Void {
		nativeLibs.replace(key, {cNlFiles: files, cNlMtime: timestamp});
	}

	public function getNativeLib(key:String):Null<CachedNativeLib> {
		return nativeLibs.findOpt(key);
	}

	/* tasks */
	public function addTask(task:ServerTask):Void {
		tasks = PriorityQueues.insert(tasks, task.getPriority(), task);
	}

	public function hasTask():Bool {
		return !PriorityQueues.isEmpty(tasks);
	}

	public function getTask():ServerTask {
		var r = PriorityQueues.extract(tasks);
		tasks = r.queue;
		return r.element;
	}

	public function runTasks(recursive:Bool, f:ServerTask->Bool):Void {
		function loop(acc:PriorityQueue<ServerTask>):PriorityQueue<ServerTask> {
			var current = tasks;
			tasks = Empty;
			function f2(state:{ranTask:Bool, acc:PriorityQueue<ServerTask>}, prio:Int, task:ServerTask) {
				if (f(task)) {
					task.run();
					return {ranTask: true, acc: state.acc};
				} else
					return {ranTask: state.ranTask, acc: PriorityQueues.insert(state.acc, prio, task)};
			}
			var r = PriorityQueues.fold(current, f2, {ranTask: false, acc: acc});
			if (recursive && r.ranTask) return loop(r.acc);
			else return r.acc;
		}
		tasks = PriorityQueues.merge(tasks, loop(Empty));
	}

	/* context lifecycle */
	/* Remove context caches that haven't been accessed for [max_age_seconds] seconds.
		This prevents unbounded accumulation of stale contexts when defines change between
		compilations, creating new signatures each time.

		A stale context is only removed if no live (non-stale) context transitively
		reaches it via `children` edges. Otherwise the next dep walk on a live
		module would `get_context` the removed signature, get back a freshly-created
		empty context, and crash with "Could not find dependency". */
	public function removeStaleContexts(maxAgeSeconds:Int):Int {
		var now = Sys.time();
		var threshold = now - maxAgeSeconds;
		function isStale(cc:ContextCache) return cc.getLastAccessTime() < threshold;
		/* Short-circuit: nothing stale, nothing to do. */
		var anyStale = contexts.fold((_, cc, acc) -> acc || isStale(cc), false);
		if (!anyStale) return 0;
		else {
			/* Transitive closure of "kept": start with non-stale contexts, follow
				each kept context's children edges. */
			var kept = CompilationCache.stringTable();
			var worklist:Array<ContextCache> = [];
			contexts.iter(function(sign, cc) {
				if (!isStale(cc)) {
					kept.replace(sign, true);
					worklist.unshift(cc);
				}
			});
			while (worklist.length > 0) {
				var cc = worklist.shift();
				cc.getChildren().iter(function(targetSign, _) {
					if (!kept.mem(targetSign)) {
						kept.replace(targetSign, true);
						switch contexts.findOpt(targetSign) {
							case null:
							case targetCc:
								worklist.unshift(targetCc);
						}
					}
				});
			}
			var toRemove = contexts.fold(function(sign, cc, acc:Array<String>) {
				if (isStale(cc) && !kept.mem(sign)) acc.unshift(sign);
				return acc;
			}, []);
			for (sign in toRemove) contexts.remove(sign);
			if (toRemove.length > 0) {
				contextList = contextList.filter(cc -> toRemove.indexOf(cc.getSign()) < 0);
			}
			return toRemove.length;
		}
	}

	/* Pointers for memory inspection. */
	public function getPointers():haxe.ds.Vector<Dynamic> return vector(contexts, haxelib, directories, nativeLibs);
}
