package context.display;

import core.Globals;
import core.Json.JsonValue;
import core.TType;
import core.TFunctions.*;
import core.json.Genjson.*;
import compiler.CompilationCache;
import context.Common;
import context.Memory;
import haxe.ds.IntMap;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeGc;
#end

// port: the sizes are those Memory.Objsize measures on the host (see Memory.hx).
class DisplayMemory {
	// port: get_memory_json, as a report (cacheMemory, contextMemory, moduleMemory, measured in
	// ... its order) and the report's JSON (cacheMemoryJson, ...)
	public static function cacheMemory(cs:Cache):CacheMemory {
		var size = Objsize.heapBytes();
		var cacheMem = cs.getPointers();
		var contexts = cs.getContexts();
		var jContexts = contexts.map(cc -> {context: cc, size: Memory.memSize(cc)});
		function memSize2(v:Dynamic, exclude:Array<Dynamic>):Int {
			return Objsize.sizeWithHeaders(Objsize.objsize(v, exclude, []));
		}
		function mem(name:String, size:Int, ?child:Array<MemoryItem>):MemoryItem
			return {name: name, size: size, child: child};
		var interpJson = switch typing.MacroContext.macroInterpCache {
			case null:
				mem("macro interpreter", Memory.memSize(typing.MacroContext.macroInterpCache));
			case interp:
				var eval = macros.eval.EvalContext.getEval(interp);
				var i:Array<Dynamic> = [interp];
				var ie:Array<Dynamic> = [interp, eval];
				mem("macro interpreter", Memory.memSize(typing.MacroContext.macroInterpCache), [
					mem("builtins", memSize2(interp.builtins, i)),
					mem("debug", memSize2(interp.debug, i)),
					mem("curapi", memSize2(interp.curapi, i)),
					mem("type_cache", memSize2(interp.typeCache, i)),
					mem("overrides", memSize2(interp.overrides, i)),
					mem("array_prototype", memSize2(interp.arrayPrototype, i)),
					mem("string_prototype", memSize2(interp.stringPrototype, i)),
					mem("vector_prototype", memSize2(interp.vectorPrototype, i)),
					mem("instance_prototypes", memSize2(interp.instancePrototypes, i)),
					mem("static_prototypes", memSize2(interp.staticPrototypes, i)),
					mem("constructors", memSize2(interp.constructors, i)),
					mem("file_keys", memSize2(interp.fileKeys, i)),
					mem("toplevel", memSize2(interp.toplevel, i)),
					mem("eval", memSize2(eval, i), [
						switch eval.env {
							case null:
								mem("env", memSize2(eval.env, ie));
							case env:
								var iee:Array<Dynamic> = [interp, eval, env];
								mem("env", memSize2(eval.env, ie), [
									mem("env_info", memSize2(env.envInfo, iee)),
									mem("env_debug", memSize2(env.envDebug, iee)),
									mem("env_locals", memSize2(env.envLocals, iee)),
									mem("env_captures", memSize2(env.envCaptures, iee)),
									mem("env_extra_locals", memSize2(env.envExtraLocals, iee)),
									mem("env_parent", memSize2(env.envParent, iee)),
									mem("env_eval", memSize2(env.envEval, iee)),
								]);
						},
						mem("thread", memSize2(eval.thread, ie), [
							mem("tthread", memSize2(eval.thread.threadMode, [interp, eval, eval.thread])),
							mem("tdeque", memSize2(eval.thread.threadDeque, [interp, eval, eval.thread])),
							mem("tstorage", memSize2(eval.evalStorage, [interp, eval, eval.thread])),
						]),
						mem("debug_state", memSize2(eval.debugState, ie)),
						mem("breakpoint", memSize2(eval.breakpoint, ie)),
						mem("caught_types", memSize2(eval.caughtTypes, ie)),
						mem("caught_exception", memSize2(eval.caughtException, ie)),
						mem("last_return", memSize2(eval.lastReturn, ie)),
						mem("debug_channel", memSize2(eval.debugChannel, ie)),
					]),
					mem("evals", memSize2(interp.evals, i)),
					mem("exception_stack", memSize2(eval.exceptionStack, i)),
				]);
		}
		var totalCache = Memory.memSize(cs);
		var contextCache = Memory.memSize(cacheMem[0]);
		var haxelibCache = Memory.memSize(cacheMem[1]);
		var directoryCache = Memory.memSize(cacheMem[2]);
		var nativeLibCache = Memory.memSize(cacheMem[3]);
		return {
			contexts: jContexts,
			totalCache: totalCache,
			contextCache: contextCache,
			haxelibCache: haxelibCache,
			directoryCache: directoryCache,
			nativeLibCache: nativeLibCache,
			additionalSizes: [interpJson].concat([
					/* jobject ["name",jstring "macro stdlib";"size",jint (mem_size (EvalContext.GlobalState.stdlib))];
						jobject ["name",jstring "macro macro_lib";"size",jint (mem_size (EvalContext.GlobalState.macro_lib))]; */
					mem("last completion result", Memory.memSize(DisplayException.lastCompletionResult)),
					mem("Lexer file cache", Memory.memSize(@:privateAccess syntax.Lexer.allFiles)),
					mem("GC heap words", Std.int(size)),
				])
		};
	}

	public static function contextMemory(cs:Cache, sign:String):ContextMemory {
		var cc = cs.getContext(sign);
		var allModules = allModulesMap(cs);
		var l = cc.getModules().fold(function(_, m:ModuleDef, acc:Array<{m:ModuleDef, mm:ModuleMemory}>) {
			acc.unshift({m: m, mm: Memory.getModuleMemory(cs, allModules, m)});
			return acc;
		}, []);
		haxe.ds.ArraySort.sort(l, (a, b) -> compareInt(b.mm.size, a.mm.size));
		var leaks:Array<{m:ModuleDef, leaks:Array<String>}> = [];
		var l = l.map(function(e) {
			if (e.mm.reached) leaks.unshift({m: e.m, leaks: e.mm.leaks});
			return {module: e.m, size: e.mm.size};
		});
		var cacheMem = cc.getPointers();
		var syntaxCache = Memory.memSize(cacheMem[0]);
		var moduleCache = Memory.memSize(cacheMem[1]);
		var binaryCache = Memory.memSize(cacheMem[2]);
		return {
			leaks: leaks.map(e -> {module: e.m, leaks: e.leaks}),
			syntaxCache: syntaxCache,
			moduleCache: moduleCache,
			modules: l,
			binaryCache: binaryCache
		};
	}

	public static function moduleMemory(cs:Cache, sign:String, path:GlobalTypePath):ModuleMemoryReport {
		var cc = cs.getContext(sign);
		var m = cc.findModule(path);
		var allModules = allModulesMap(cs);
		var mm = Memory.getModuleMemory(cs, allModules, m);
		var deps = Memory.updateModuleTypeDeps(mm.deps, m);
		var out = Memory.getOut(mm.out);
		var types = m.mTypes.map(function(md) {
			var fields:Array<{field:TClassField, size:Int}>, inf:ObjsizeInfo;
			switch md {
				case TClassDecl(c):
					var ownDeps = deps;
					function field(acc:Array<{cf:TClassField, size:Int}>, cf:TClassField) {
						var repr:Dynamic = cf;
						ownDeps = ownDeps.filter(repr2 -> repr != repr2);
						var deps = deps.filter(repr2 -> repr2 != repr);
						var size = Objsize.sizeWithHeaders(Objsize.objsize(cf, deps, out));
						acc.unshift({cf: cf, size: size});
						return acc;
					}
					var fields_ = Lambda.fold(c.clOrderedFields, (cf, acc) -> field(acc, cf), []);
					var fields_ = Lambda.fold(c.clOrderedStatics, (cf, acc) -> field(acc, cf), fields_);
					haxe.ds.ArraySort.sort(fields_, (a, b) -> compareInt(b.size, a.size));
					fields = fields_.map(e -> {field: e.cf, size: e.size});
					var repr:Dynamic = c;
					var deps = ownDeps.filter(repr2 -> repr2 != repr);
					inf = Objsize.objsize(c, deps, out);
				case TEnumDecl(en):
					var repr:Dynamic = en;
					var deps = deps.filter(repr2 -> repr2 != repr);
					fields = [];
					inf = Objsize.objsize(en, deps, out);
				case TTypeDecl(td):
					var repr:Dynamic = td;
					var deps = deps.filter(repr2 -> repr2 != repr);
					fields = [];
					inf = Objsize.objsize(td, deps, out);
				case TAbstractDecl(a):
					var repr:Dynamic = a;
					var deps = deps.filter(repr2 -> repr2 != repr);
					fields = [];
					inf = Objsize.objsize(a, deps, out);
			}
			var size = Objsize.sizeWithHeaders(inf);
			return {type: md, size: size, fields: fields};
		});
		haxe.ds.ArraySort.sort(types, (a, b) -> compareInt(b.size, a.size));
		return {moduleExtra: Objsize.sizeWithHeaders(Objsize.objsize(m.mExtra, deps, out)), types: types};
	}

	// port: get_memory_json's JSON (MCache)
	public static function cacheMemoryJson(r:CacheMemory):JsonValue {
		function item(i:MemoryItem):JsonValue {
			var fl = [kv("name", jstring(i.name)), kv("size", jint(i.size))];
			if (i.child != null) fl.push(kv("child", jarray(i.child.map(item))));
			return jobject(fl);
		}
		return jobject([
			kv("contexts", jarray(r.contexts.map(c -> jobject([kv("context", c.context.getJson()), kv("size", jint(c.size)),])))),
			kv("memory", jobject([
				kv("totalCache", jint(r.totalCache)),
				kv("contextCache", jint(r.contextCache)),
				kv("haxelibCache", jint(r.haxelibCache)),
				kv("directoryCache", jint(r.directoryCache)),
				kv("nativeLibCache", jint(r.nativeLibCache)),
				kv("additionalSizes", jarray(r.additionalSizes.map(item)))
			]))
		]);
	}

	// port: get_memory_json's JSON (MContext)
	public static function contextMemoryJson(r:ContextMemory):JsonValue {
		var leaks = switch r.leaks {
			case []: jnull;
			case leaks:
				jarray(leaks.map(function(e) {
					var jleaks = e.leaks.map(s -> jobject([kv("path", jstring(s))]));
					return jobject([kv("path", jstring(Globals.sTypePath(e.module.mPath))), kv("leaks", jarray(jleaks)),]);
				}));
		}
		var l = r.modules.map(e -> jobject([
			kv("path", jstring(Globals.sTypePath(e.module.mPath))),
			kv("size", jint(e.size)),
			kv("hasTypes", jbool(switch e.module.mExtra.mKind {
				case MCode | MMacro: true;
				case _: false;
			})),
		]));
		return jobject([
			kv("leaks", leaks),
			kv("syntaxCache", jobject([kv("size", jint(r.syntaxCache)),])),
			kv("moduleCache", jobject([kv("size", jint(r.moduleCache)), kv("list", jarray(l)),])),
			kv("binaryCache", jobject([kv("size", jint(r.binaryCache)),])),
		]);
	}

	// port: get_memory_json's JSON (MModule)
	public static function moduleMemoryJson(r:ModuleMemoryReport):JsonValue {
		var types = r.types.map(t -> jobject([
			kv("name", jstring(Globals.sTypePath((tInfos(t.type)).mtPath))),
			kv("size", jint(t.size)),
			kv("pos", generatePosAsLocation((tInfos(t.type)).mtNamePos)),
			kv("fields", jarray(t.fields.map(f -> jobject([
				kv("name", jstring(f.field.cfName)),
				kv("size", jint(f.size)),
				kv("pos", generatePosAsLocation(f.field.cfNamePos)),
			])))),
		]));
		return jobject([kv("moduleExtra", jint(r.moduleExtra)), kv("types", jarray(types)),]);
	}

	static inline function compareInt(a:Int, b:Int):Int return a < b ? -1 : (a > b ? 1 : 0);

	// port: List.fold_left (fun acc m -> PMap.add m.m_id m acc) PMap.empty cs#get_modules
	static function allModulesMap(cs:Cache):IntMap<ModuleDef> {
		var all = new IntMap<ModuleDef>();
		for (m in cs.getModules()) all.set(m.mId, m);
		return all;
	}

	public static function displayMemory(com:CommonContext):Void {
		var verbose = com.verbose;
		var print = Sys.println;
		// port: Gc.full_major (); Gc.compact (): a collection of the host
		#if (target.name == "hxmc")
		NativeGc.collect(true);
		#end
		// port: Gc.stat (): the host reports its heap size, not the free part
		var heap = Std.int(Objsize.heapBytes());
		print("Total Allocated Memory " + Memory.fmtSize(heap));
		print("Free Memory " + Memory.fmtSize(0));
		var c = com.cs;
		print("Total cache size " + Memory.size(c));
		/* print ("  haxelib " ^ size c.c_haxelib); */
		/* print ("  parsed ast " ^ size c.c_files ^ " (" ^ string_of_int (Hashtbl.length c.c_files) ^ " files stored)"); */
		/* print ("  typed modules " ^ size c.c_modules ^ " (" ^ string_of_int (Hashtbl.length c.c_modules) ^ " modules stored)"); */
		var moduleList = c.getModules();
		var allModules = allModulesMap(c);
		var modules:Array<{m:ModuleDef, size:Int, r:ModuleMemory}> = [];
		for (m in moduleList) {
			var r = Memory.getModuleMemory(c, allModules, m);
			modules.unshift({m: m, size: r.size, r: r});
		}
		var curKey = "", tcount = 0, mcount = 0;
		haxe.ds.ArraySort.sort(modules, function(a, b) {
			var k1 = a.m.mExtra.mSign, k2 = b.m.mExtra.mSign;
			return if (k1 == k2) a.size - b.size else if (k1 > k2) 1 else -1;
		});
		for (e in modules) {
			var m = e.m;
			var key = m.mExtra.mSign;
			if (key != curKey) {
				print('    --- CONFIG $key ----------------------------');
				curKey = key;
			}
			print('    ${Globals.sTypePath(m.mPath)} : ${Memory.fmtSize(e.size)}');
			if (e.r.reached) try {
				mcount++;
				var lcount = 0;
				function leak(l:String) {
					lcount++;
					tcount++;
					print('      LEAK $l');
					if (lcount >= 3 && tcount >= 100 && !verbose) {
						print('      ...');
						throw new macros.eval.EvalDebugMisc.Exit();
					}
				}
				for (l in e.r.leaks) leak(l);
			} catch (_:macros.eval.EvalDebugMisc.Exit) {}
			if (verbose) {
				print('      ${e.r.deps.length} total deps');
				var keys = [for (k in m.mExtra.mDeps.keys()) k];
				keys.sort(compareInt);
				for (k in keys) {
					var mdep = m.mExtra.mDeps.get(k);
					var md = (com.cs.getContext(mdep.mdSign)).findModule(mdep.mdPath);
					print('      dep ${Globals.sTypePath(mdep.mdPath)}${Memory.moduleSign(key, md)}');
				}
			}
		}
		if (mcount > 0) print("*** " + Std.string(mcount) + " modules have leaks !");
		print("Cache dump complete");
	}
}

private typedef ModuleMemory = {size:Int, reached:Bool, deps:Array<Dynamic>, out:IntMap<ModuleDef>, leaks:Array<String>};

/** A size in server/memory's additional sizes, with its parts. */
typedef MemoryItem = {name:String, size:Int, ?child:Array<MemoryItem>};

/** server/memory: the cache's sizes (Memory.Objsize's, in bytes). */
typedef CacheMemory = {
	contexts:Array<{context:ContextCache, size:Int}>,
	totalCache:Int,
	contextCache:Int,
	haxelibCache:Int,
	directoryCache:Int,
	nativeLibCache:Int,
	additionalSizes:Array<MemoryItem>
};

/** server/memory/context: a context's sizes; its modules largest first, and the leaks
	of those that reach modules they do not depend on. */
typedef ContextMemory = {
	leaks:Array<{module:ModuleDef, leaks:Array<String>}>,
	syntaxCache:Int,
	moduleCache:Int,
	modules:Array<{module:ModuleDef, size:Int}>,
	binaryCache:Int
};

/** server/memory/module: a module's sizes, its types (and their fields) largest first. */
typedef ModuleMemoryReport = {
	moduleExtra:Int,
	types:Array<{type:ModuleType, size:Int, fields:Array<{field:TClassField, size:Int}>}>
};
