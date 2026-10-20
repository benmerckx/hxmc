package hxmc;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;
import core.Globals.GlobalTypePath;
import core.TType;
import compiler.hxb.HxbData;
import compiler.server.ServerCache;
import context.Common;
import core.Message.CompilerMessageKind;
import core.Message.WarningMode;
import hxmc.ModuleStore;

// The compilation server's module cache made durable (docs/plans/compiler.md, "Cached
// modules"): a build writes the typed modules it ends with, as the server
// keeps them in its HXB mode (each module's HXB chunks, its dependencies,
// kind, file and check policy), into a store in the user's cache directory
// (ModuleStore.hx); the next build puts them back in the server's cache
// before typing, and the server's checks decide, module by module and only
// for the modules the build loads, which are still good; the HXB is read
// and decoded on demand.
//
// Defines: a module is kept with the defines it read (its file's conditions,
// its macros' Context.defined and getDefines) and those the compiler read
// in the build that typed it (Define.readHook: the typer's and filters'
// options, the target's); a build restores the variant whose reads have its
// values, so a define only some modules read leaves the others (the std)
// good, in a store shared by every signature. The macros' context, when it
// does not exist yet, gets the defines it will have (predicted as
// MacroContext does it, checked when it is created).
//
// Validity (ServerCache.checkModuleHook, check below): the module's file
// (a content hash where the date or size differ: a fresh checkout changes
// every date; a date within RACY seconds of the parse is not trusted), the
// file its path resolves to now (a module shadowed by a new file earlier in
// the class path is typed again), its defines, and its dependencies by hash:
// each dependency's interface (ModuleInterface: its declarations without
// the bodies its users cannot see, and its own dependencies' interfaces,
// per strongly connected component) as it was when the module was typed, or
// its whole content (its source and everything it depends on) for a macro's
// module and modules typed with macros. A dependency typed again whose
// interface did not change leaves its dependents good (early cutoff:
// ServerCache.dependencyDirtyHook; it is typed from its source where the
// server expects it cached, loadDirtyModuleHook).
//
// A build from the cache writes the same output as one without it
// (hxmc/test/ModuleCacheCheck.hx), which takes two things the server's HXB
// cache does not keep: the modifiers of unbound monomorphs (Null<Unknown>:
// CheckingHxbWriter, given back to the reader's monomorphs through
// ServerCache.readerCreatedHook) and what the sort of the types walks of a
// restored module, whose expressions are the filtered ones (Skeletons,
// through Finalization.sortExprHook).
//
// On by default; HXMC_MODULE_CACHE=0 or -D hxmc.no-module-cache turns it
// off (HXMC_MODULE_CACHE=0 also when -D hxmc.module-cache is given).
// Through `haxe` (HaxeMain) and the tool alike, for every target. Not used
// (the build types everything from source): display requests, the
// compilation server and its clients (already in memory), builds of several
// parts (--next, --each), init macros (--macro: their effects are not in the
// key yet), deprecated defines, HXB libraries or output, native libraries,
// WASI. A callback a macro registers while a module is typed
// (Context.onGenerate, onAfterTyping, onAfterGenerate) makes that module
// typed every build; outside the typing of a module, the build writes
// nothing (a module restored later would not do it again).
//
// Macro state: the static variables of macro classes (not the std's) the
// macros run in a module's typing use are kept with its variant
// (EvalJit.staticVarHook: state such as a registry an @:autoBuild fills
// for another macro, or a counter naming generated types). The module is
// restored while no macro of the build uses that state; one that does
// after the module was restored runs the build again, with the modules
// whose macros keep state there typed from their source
// (HXMC_MODULE_CACHE_RETYPE); an edited module whose macros keep state has
// the others that keep it there typed from the start.
//
// Nondeterministic macros (EvalStdLib.volatileHook, fileHook, envHook: the
// macro std's natives, for the module being typed when the macro runs): a
// call whose result changes from run to run (the time, randomness, the
// network, processes) makes the module typed every build ("!" in its
// macroState, "!!" when its dependents can copy the result: then what
// stands for it in their hashes is new every build); a file or an
// environment variable a macro reads is a read of the module (roles 3 and
// 2 beside the defines' 0 and 1), kept with its value. @:hxmc.noCache and
// -D hxmc.no-cache type a module every build, its dependents with it.
// HXMC_STATS=1 prints what the cache did, HXMC_MODULE_CACHE_LOG=1 each
// module checked, each one not kept and why one is typed every build.
//
// A build rewrites its key's index when it typed modules or restored other
// variants: its modules first, then the variants it did not use, at most
// MAX_VARIANTS per module. Module and variable ids continue from the
// store's (the server keeps the ids of the modules and variables it
// restores). The tool directories, the indexes and the packs no index names
// are trimmed by last use and size (CacheDir.trim).
class ModuleCache {
	static inline var ID_LIMIT = 1 << 30;
	static inline var MAX_VARIANTS = 4;
	static final noMonos = {
		var o = new BytesOutput();
		o.writeInt32(0);
		o.getBytes();
	}

	static var state:Null<ModuleCacheState> = null;
	static var hookCalls = 0;
	static var parseHookInstalled = false;
	static var start = haxe.Timer.stamp();
	static final mutex = new sys.thread.Mutex();
	static var mainThread:Null<sys.thread.Thread> = null;
	// the defines read before the cache opened, per defines context
	static var early:Array<{ctx:core.Define.DefineContext, keys:Map<String, Bool>}> = [];
	// each context's typer (to type a module from its source)
	static var typers:Array<{com:CommonContext, g:context.Typecore.TyperGlobals}> = [];

	public static function current():Null<ModuleCacheState>
		return state;

	public static function install() {
		compiler.Compiler.beforeTypingHook = hook;
		if (Sys.systemName() == "Wasi") return;
		mainThread = sys.thread.Thread.current();
		core.Define.readHook = onRead;
		Common.externalDefinesHook = onExternal;
		typing.TyperEntry.createdHook = onTyper;
		ServerCache.dependencyDirtyHook = onDependencyDirty;
		ServerCache.loadDirtyModuleHook = loadDirty;
		ServerCache.readerFindModuleHook = onReaderFind;
		typing.TypeloadModule.typeFromSourceHook = onTypeFromSource;
		typing.TypeloadModule.buildClassHook = onBuildClass;
		compiler.hxb.HxbReader.missingFieldHook = onMissingField;
		core.TUnification.maybeUsedHook = onMaybeUsed;
		macros.eval.EvalJit.staticVarHook = onStaticVar;
		macros.eval.EvalStdLib.volatileHook = onVolatile;
		macros.eval.EvalStdLib.fileHook = onFileRead;
		macros.eval.EvalStdLib.envHook = onEnvRead;
		// (a module of the macros' context restored as processed: -1, ModuleStore.readExtra)
		typing.MacroContext.processedTypeHook = mt -> state != null && core.TFunctions.tModule(mt).mExtra.mProcessed < 0;
		// (a lazy typing continues the typing of the module that made it)
		Common.lazyHook = function(f:Void->T):Void->T {
			var s = state;
			if (s == null || s.typingStack.length == 0) return f;
			var maker = s.typingStack[s.typingStack.length - 1];
			return function() {
				if (state != s) return f();
				s.typingStack.push(maker);
				var r = try f() catch (x:Dynamic) {
					s.typingStack.pop();
					throw x;
				}
				s.typingStack.pop();
				return r;
			};
		};
		// (a delayed task continues the typing of the module that delayed it)
		context.Typecore.delayHook = function(f:Void->Void):Void->Void {
			var s = state;
			if (s == null || s.typingStack.length == 0) return f;
			var maker = s.typingStack[s.typingStack.length - 1];
			return function() {
				var s2 = state;
				if (s2 != s) {
					f();
					return;
				}
				s.typingStack.push(maker);
				try f() catch (x:Dynamic) {
					s.typingStack.pop();
					throw x;
				}
				s.typingStack.pop();
			};
		};
		wrapTypeExpr();
	}

	// Typecore.typeExprRef, wrapped to know the module whose code is being
	// typed (the maker of the structural marks); again after each typer's
	// creation, which sets the reference anew (Typer.initialize)
	static var typeExprWrapper:Null<Dynamic> = null;

	static function wrapTypeExpr() {
		if (typeExprWrapper != null && Reflect.compareMethods(context.Typecore.typeExprRef, typeExprWrapper)) return;
		var typeExpr = context.Typecore.typeExprRef;
		var w = function(ctx:context.Typecore.Typer, e:core.Ast.Expr, withType:core.WithType.WithTypeValue, ?mode:context.Typecore.AccessMode):TExpr {
			var s = state;
			if (s == null) return typeExpr(ctx, e, withType, mode);
			s.typingStack.push(ctx.m.curmod);
			s.typerStack.push(ctx);
			s.typerDepths.push(s.typingStack.length);
			var r = try typeExpr(ctx, e, withType, mode) catch (x:Dynamic) {
				s.typerStack.pop();
				s.typerDepths.pop();
				s.typingStack.pop();
				throw x;
			}
			s.typerStack.pop();
			s.typerDepths.pop();
			s.typingStack.pop();
			return r;
		}
		typeExprWrapper = w;
		context.Typecore.typeExprRef = w;
	}

	// TUnification.maybeUsedHook: a class field marked as maybe used through
	// a structure (CfMaybeUsed, which DCE reads), and its accessors, by the
	// module being typed
	static function onMaybeUsed(cl:Null<TClass>, f1:TClassField, f2:Null<TClassField>) {
		var s = state;
		if (s == null) return;
		var maker = s.typingStack.length > 0 ? s.typingStack[s.typingStack.length - 1] : null;
		mutex.acquire();
		s.liveMarks.push({maker: maker, cf: f1});
		if (cl != null && f2 != null)
			switch f2.cfKind {
				case Var(v):
					var names = [];
					switch v.vRead {
						case AccCall | AccPrivateCall: names.push("get_" + f1.cfName);
						case _:
					}
					switch v.vWrite {
						case AccCall | AccPrivateCall: names.push("set_" + f1.cfName);
						case _:
					}
					for (n in names) {
						var f = try core.TFunctions.rawClassField(cf -> cf.cfType, cl, [for (_ in cl.clParams) core.TFunctions.tDynamic], n).field catch (_:Dynamic) null;
						if (f != null) s.liveMarks.push({maker: maker, cf: f});
					}
				case _:
			}
		mutex.release();
	}

	// EvalJit.staticVarHook: a macro used a static variable of a macro class
	// (state kept between macro calls), in the typing of a module or not; the
	// std's classes left out (their variables are constant tables, caches of
	// the platform: none a library's macros keep their state in)
	static function onStaticVar(c:TClass, write:Bool) {
		var s = state;
		if (s == null) return;
		var maker = s.typingStack.length == 0 ? null : s.typingStack[s.typingStack.length - 1];
		if (maker == s.lastStateMaker && c == s.lastStateClass) return;
		s.lastStateMaker = maker;
		s.lastStateClass = c;
		mutex.acquire();
		var std = s.stdClass.get(c);
		if (std == null) s.stdClass.set(c, std = s.isStdFile(core.Path.UniqueKey.lazyPath(c.clModule.mExtra.mFile)));
		if (std) {
			mutex.release();
			return;
		}
		var name = core.Globals.sTypePath(c.clPath);
		if (maker != null) s.liveState.push({maker: maker, path: name});
		s.touched.set(name, true);
		var r = s.restoredState.get(name);
		mutex.release();
		// (restored modules' macros kept state there, which they did not make
		// again in this build: the build again, the modules typed)
		if (r != null && r.length > 0) again(s, name, r);
	}

	// the build run again, with the modules whose macros keep state in the
	// class typed from their source (HXMC_MODULE_CACHE_RETYPE), as soon as
	// a macro of this build uses it after such a module was restored
	static function again(s:ModuleCacheState, name:String, restored:Array<String>) {
		var prev = Sys.getEnv(RETYPE);
		var l = prev == null || prev == "" ? [] : prev.split(",");
		if (l.indexOf(name) >= 0 || l.length >= 64) Sys.putEnv("HXMC_MODULE_CACHE", "0") else {
			l.push(name);
			Sys.putEnv(RETYPE, l.join(","));
		}
		if (stats() || s.log)
			Sys.println("hxmc: module cache: " + name + " keeps state of restored modules' macros (" + restored.join(", ") + "), which this build's macros use: the build again, those typed");
		try Sys.stdout().flush() catch (_:Dynamic) {}
		try Sys.stderr().flush() catch (_:Dynamic) {}
		Sys.exit(Sys.command(Sys.programPath(), Sys.args()));
	}

	static inline var RETYPE = "HXMC_MODULE_CACHE_RETYPE";

	// the role and key of the module a maker stands for (a ModuleDef, or a
	// module being typed from its source); null: of no context the store knows
	static function makerKey(s:ModuleCacheState, maker:Dynamic):Null<String> {
		if (Std.isOfType(maker, core.TType.ModuleDef)) {
			var m:ModuleDef = maker;
			var r = s.roleOfSign(m.mExtra.mSign);
			return r < 0 ? null : r + "|" + key(m.mPath);
		}
		var x:{com:CommonContext, path:GlobalTypePath} = maker;
		var r = s.roleOfSign(context.CommonCache.getCacheSign(x.com));
		return r < 0 ? null : r + "|" + key(x.path);
	}

	// whether typing is still going on (a macro's call outside the typing of
	// a module then is one a restored module would not make again)
	static function stillTyping(s:ModuleCacheState):Bool
		return s.com.stage.getIndex() < CTypingDone.getIndex();

	// EvalStdLib.volatileHook: a macro called something whose result changes
	// from run to run (the time, randomness, the network, a process): the
	// module being typed is typed every build. Its dependents see it through
	// its interface as parsed, unless the call is in what they can copy (an
	// inline or macro field, a field whose type is not written out, a build
	// macro): then its interface is new every build too ("!!")
	static function onVolatile(what:String) {
		var s = state;
		if (s == null) return;
		var maker = s.typingStack.length == 0 ? null : s.typingStack[s.typingStack.length - 1];
		if (maker == null) {
			if (stillTyping(s) && s.volatileReason == null) s.volatileReason = "a macro called " + what + " outside the typing of a module";
			return;
		}
		if (maker == s.lastVolatileMaker && s.lastVolatileLeaky) return;
		var leaky = leakyCall(s);
		if (maker == s.lastVolatileMaker && !leaky) return;
		s.lastVolatileMaker = maker;
		s.lastVolatileLeaky = leaky;
		var k = makerKey(s, maker);
		if (k == null) return;
		mutex.acquire();
		var known = s.volatileMakers.get(k);
		if (known == true || (known == false && !leaky)) {
			mutex.release();
			return;
		}
		s.volatileMakers.set(k, leaky);
		mutex.release();
		var reason = "macro called " + what + callSite(s);
		mutex.acquire();
		s.liveState.push({maker: maker, path: (leaky ? "!!" : "!") + reason});
		mutex.release();
	}

	// whether the macro running now was called where the module's dependents
	// can copy its result (see onVolatile)
	static function leakyCall(s:ModuleCacheState):Bool {
		var n = s.typerStack.length;
		if (n == 0) return true;
		// (a build macro, a lazy typing: not an expression of a field)
		if (s.typerDepths[n - 1] != s.typingStack.length) return true;
		var cf = s.typerStack[n - 1].f.curfield;
		if (cf == null) return true;
		switch cf.cfKind {
			case Method(MethInline | MethMacro): return true;
			case Var(v) if (v.vRead == AccInline): return true;
			case _:
		}
		return inferred(cf.cfType, 0);
	}

	// whether a field's type has parts inferred from its expression
	static function inferred(t:T, depth:Int):Bool {
		if (depth > 16) return true;
		return switch t {
			case TMono(_): true;
			// (a field being typed: its type as declared)
			case TLazy(l):
				switch l.value {
					case LAvailable(x) | LProcessing(x): inferred(x, depth + 1);
					case LWait(_): true;
				}
			case TEnum(_, l) | TInst(_, l) | TType(_, l) | TAbstract(_, l):
				var r = false;
				for (x in l)
					if (inferred(x, depth + 1)) r = true;
				r;
			case TFun(sig):
				var r = inferred(sig.ret, depth + 1);
				for (a in sig.args)
					if (inferred(a.type, depth + 1)) r = true;
				r;
			case TAnon(a):
				var r = false;
				for (f in a.aFields)
					if (inferred(f.cfType, depth + 1)) r = true;
				r;
			case TDynamic(x): x != null && inferred(x, depth + 1);
		}
	}

	// where the macro made the call: the innermost frame of Eval's stack in
	// a file of no std (else the innermost), as file:line
	static function callSite(s:ModuleCacheState):String {
		var env = try macros.eval.EvalContext.getEvalOpt(null).env catch (_:Dynamic) null;
		var first:Null<String> = null;
		var cwd = haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(Sys.getCwd()));
		var depth = 0;
		while (env != null && depth++ < 256) {
			var file = try macros.eval.EvalHash.revHash(env.envInfo.pfile) catch (_:Dynamic) null;
			if (file != null && file != "" && file != "?") {
				var line = try syntax.Lexer.findPos(new core.Globals.Pos(file, env.envLeavePmin, env.envLeavePmax)).line catch (_:Dynamic) 0;
				var f = haxe.io.Path.normalize(file);
				if (StringTools.startsWith(f, cwd)) f = f.substr(cwd.length);
				var site = f + ":" + line;
				if (first == null) first = site;
				if (!s.isStdFile(file)) return " at " + site;
			}
			env = env.envParent;
		}
		return first == null ? "" : " at " + first;
	}

	// EvalStdLib.fileHook: a macro read a file (its content, a directory's
	// listing, whether it exists, its status, its full path): a read of the
	// module being typed, kept with its value (ModuleCacheState.value, role 3)
	static function onFileRead(kind:String, path:String) {
		var s = state;
		if (s == null) return;
		var abs = haxe.io.Path.normalize(try FileSystem.absolutePath(path) catch (_:Dynamic) path);
		macroRead(s, 3, kind + ":" + abs, "a macro read " + path);
	}

	// EvalStdLib.envHook: a macro read an environment variable (null: the
	// whole environment): a read of the module being typed (role 2)
	static function onEnvRead(name:Null<String>) {
		var s = state;
		if (s == null) return;
		macroRead(s, 2, name == null ? "*" : name, "a macro read the environment");
	}

	static function macroRead(s:ModuleCacheState, role:Int, name:String, what:String) {
		var maker = s.typingStack.length == 0 ? null : s.typingStack[s.typingStack.length - 1];
		if (maker == null) {
			if (stillTyping(s) && s.volatileReason == null) s.volatileReason = what + " outside the typing of a module";
			return;
		}
		var k = makerKey(s, maker);
		if (k == null) return;
		mutex.acquire();
		var l = s.moduleReads.get(k);
		if (l == null) s.moduleReads.set(k, l = new Map());
		l.set(role + "\x00" + name, true);
		mutex.release();
	}

	// -D hxmc.no-cache=<entries> (comma-separated: a package or module path,
	// or a directory named so in the path of the class path the module's
	// file is in, such as a library's; without a value, every module):
	// whether it names the module. Read without Define.readHook (not a read
	// of the build's)
	static function noCache(s:ModuleCacheState, path:GlobalTypePath, file:Null<String>):Bool {
		var l = s.noCacheList;
		if (l == null) {
			var d = s.com.defines.values;
			var v = d.get("hxmc.no-cache");
			if (v == null) v = d.get("hxmc.no_cache");
			l = s.noCacheList = v == null ? [] : v == "1" || v == "" ? ["*"] : [for (x in v.split(",")) if (StringTools.trim(x) != "") StringTools.trim(x)];
		}
		if (l.length == 0) return false;
		var dotted = path.pack.concat([path.name]).join(".");
		// (the class path the file is in: its directory without the package's)
		var root = file == null ? "" : "/" + haxe.io.Path.directory(StringTools.replace(file, "\\", "/")) + "/";
		var packDir = "/" + path.pack.join("/") + (path.pack.length > 0 ? "/" : "");
		if (StringTools.endsWith(root, packDir)) root = root.substr(0, root.length - packDir.length + 1);
		for (e in l) {
			if (e == "*" || dotted == e || StringTools.startsWith(dotted, e + ".")) return true;
			if (root.indexOf("/" + e + "/") >= 0) return true;
		}
		return false;
	}

	// @:hxmc.noCache on a type of the module
	static function noCacheMeta(m:ModuleDef):Bool {
		for (t in m.mTypes) {
			var meta = core.TFunctions.tInfos(t).mtMeta;
			for (x in meta)
				if (core.Meta.toString(x.meta) == ":hxmc.noCache") return true;
		}
		return false;
	}

	// per module, the macro classes whose state its macros used (Variant.macroState)
	static function stateMakers(s:ModuleCacheState):haxe.ds.ObjectMap<ModuleDef, Array<String>> {
		var r = new haxe.ds.ObjectMap<ModuleDef, Array<String>>();
		for (ls in s.liveState) {
			var maker:Null<ModuleDef> = Std.isOfType(ls.maker, core.TType.ModuleDef) ? ls.maker : {
				var x:{com:CommonContext, path:GlobalTypePath} = ls.maker;
				x.com.moduleLut.findOpt(x.path);
			};
			if (maker == null) {
				if (s.volatileReason == null) s.volatileReason = "macro state (" + ls.path + ") kept outside the typing of a module";
				continue;
			}
			var l = r.get(maker);
			if (l == null) r.set(maker, l = []);
			// (one reason a module is typed every build: the first call whose
			// result its dependents can copy, else the first)
			if (StringTools.startsWith(ls.path, "!")) {
				var i = -1;
				for (j in 0...l.length)
					if (StringTools.startsWith(l[j], "!")) i = j;
				if (i < 0) l.push(ls.path) else if (!StringTools.startsWith(l[i], "!!") && StringTools.startsWith(ls.path, "!!")) l[i] = ls.path;
				continue;
			}
			if (l.indexOf(ls.path) < 0) l.push(ls.path);
		}
		for (l in r)
			l.sort(Reflect.compare);
		return r;
	}

	// the build's structural marks made exact (before DCE reads them): a
	// restored module's fields lose the marks its HXB kept (its users' typing
	// in an earlier build) and get those of this build's users: the ones
	// typed now marked them again, the restored ones replay theirs
	static function fixMarks(s:ModuleCacheState, coms:Array<CommonContext>) {
		var refs = new haxe.ds.ObjectMap<TClassField, String>();
		var byRef = new Map<String, TClassField>();
		var restored = [];
		for (role in 0...coms.length)
			for (m in coms[role].modules) {
				var r = s.restored(m) != null;
				if (r) restored.push(m);
				for (t in m.mTypes)
					switch t {
						case TClassDecl(c):
							var base = role + "|" + key(m.mPath) + "|" + c.clPath.name + "|";
							inline function add(cf:TClassField, k:String) {
								if (cf == null) return;
								refs.set(cf, base + k + cf.cfName);
								byRef.set(base + k + cf.cfName, cf);
								if (r) core.TFunctions.removeClassFieldFlag(cf, CfMaybeUsed);
							}
							add(c.clConstructor, "c|");
							for (cf in c.clOrderedFields)
								add(cf, "f|");
							for (cf in c.clOrderedStatics)
								add(cf, "s|");
						case _:
					}
			}
		var unattributed = 0;
		for (lm in s.liveMarks) {
			core.TFunctions.addClassFieldFlag(lm.cf, CfMaybeUsed);
			var ref = refs.get(lm.cf);
			if (ref == null) continue;
			var maker:Null<ModuleDef> = lm.maker == null ? null : Std.isOfType(lm.maker, core.TType.ModuleDef) ? lm.maker : {
				var x:{com:CommonContext, path:GlobalTypePath} = lm.maker;
				x.com.moduleLut.findOpt(x.path);
			};
			if (maker == null) {
				if (s.log) Sys.println("hxmc: module cache: a structural mark on " + ref + " outside the typing of a module");
				unattributed++;
				continue;
			}
			var l = s.madeMarks.get(maker);
			if (l == null) s.madeMarks.set(maker, l = []);
			if (l.indexOf(ref) < 0) l.push(ref);
		}
		for (m in restored)
			for (ref in s.restored(m).marks) {
				var cf = byRef.get(ref);
				if (cf != null) core.TFunctions.addClassFieldFlag(cf, CfMaybeUsed);
			}
		for (l in s.madeMarks)
			l.sort(Reflect.compare);
		s.unattributedMarks = unattributed;
		if (unattributed > 0 && s.log) Sys.println("hxmc: module cache: " + unattributed + " structural marks made outside the typing of a module");
	}

	// TypeloadModule.typeFromSourceHook: while a module of the store is typed
	// from its source, the restored modules of its cycle it loads are typed
	// from theirs too (decoded then, they would refer to its types before they
	// are ready); the others of its cycle stay restored
	static function onTypeFromSource(com:CommonContext, path:GlobalTypePath, start:Bool) {
		var s = state;
		if (s == null) return;
		if (!start) {
			s.creating.pop();
			s.typingStack.pop();
			return;
		}
		// (a module being typed from its source: its ModuleDef found later)
		s.typingStack.push({com: com, path: path});
		var v = s.variantOf(context.CommonCache.getCacheSign(com), path);
		s.creating.push(v == null ? -1 : s.sccOf(v));
		// (a module whose state was restored, typed after all: its macros make it again)
		if (v != null)
			for (c in v.macroState) {
				var l = s.restoredState.get(c);
				if (l != null) l.remove(v.roleKey());
			}
	}

	// TypeloadModule.buildClassHook: a class of a module typed from its
	// source built (its fields made), lazily, when something first asks for
	// them: part of the typing of its module (what its build macros do is
	// that module's, its macros' state among it, whichever module's typing
	// asked), and while it lasts the restored modules that refer to that
	// module are typed from their source too (cycleGuard: decoded then,
	// they would refer to fields it does not have yet)
	static function onBuildClass(c:TClass, start:Bool) {
		var s = state;
		if (s == null) return;
		if (start) {
			s.typingStack.push(c.clModule);
			s.building.push(c.clModule);
		} else {
			s.typingStack.pop();
			s.building.pop();
		}
	}

	// HxbReader.missingFieldHook: a restored module refers to a field its
	// class does not have (yet): of a module typed from its source in this
	// build whose pending passes make it (an interface's accessors, made in
	// PConnectField, which the typer runs before the code that reads them is
	// typed): those passes run now, as TypeloadModule.loadModule does
	static function onMissingField(c:TClass):Bool {
		var s = state;
		if (s == null || c.clModule == null || s.restored(c.clModule) != null) return false;
		var com = s.comOf(s.roleOfSign(c.clModule.mExtra.mSign));
		var g = com == null ? null : typerOf(com);
		if (g == null) return false;
		context.Typecore.flushPass(g, context.TyperPass.PConnectField, {name: "hxmc.module_cache", args: c.clPath.pack.concat([c.clPath.name])});
		return true;
	}

	static function wanted(com:CommonContext):Bool {
		var env = Sys.getEnv("HXMC_MODULE_CACHE");
		return env != "0" && CacheDir.define(com, "hxmc.no-module-cache") == null;
	}

	// why a build that wants the cache cannot use it (null: it can)
	static function unusable(com:CommonContext, actx:compiler.ParsedArg.ArgContext):Null<String> {
		if (hookCalls > 1 || com.partScope.hasNext) return "several compilations";
		if (com.sctx.isServer || Driver.resident) return "compilation server";
		if (actx.displayArg != null || com.display.dmsKind != DMNone) return "display request";
		if (actx.configMacros.length > 0) return "init macros";
		if (actx.hxbLibs.length > 0 || actx.nativeLibs.length > 0) return "libraries";
		if (actx.hxbOut != null) return "HXB output";
		if (Sys.systemName() == "Wasi") return "WASI";
		for (k in com.defines.values.keys())
			if (core.Define.deprecationLut.exists(k)) return "deprecated define " + k;
		return null;
	}

	static function hook(com:CommonContext, actx:compiler.ParsedArg.ArgContext) {
		hookCalls++;
		state = null;
		ServerCache.checkModuleHook = null;
		typing.Finalization.sortExprHook = null;
		var why = wanted(com) ? unusable(com, actx) : "off";
		var s = why == null ? open(com) : null;
		early = [];
		if (s == null) {
			if (why == null) why = "no cache directory";
			if (why != "off" && stats()) Sys.println('hxmc: module cache not used ($why)');
			return;
		}
		state = s;
		ServerCache.checkModuleHook = check;
		typing.Finalization.sortExprHook = Skeletons.sortExpr;
		// (what the sort of the types walks, of every class typed: before the
		// filters change it)
		com.callbacks.addAfterTyping(_ -> Skeletons.computeAll(com));
		if (!parseHookInstalled) {
			parseHookInstalled = true;
			// (the blob of a restored module and the modifiers of its
			// monomorphs, once the server has read it)
			ServerCache.readerCreatedHook = function(com, path, reader) {
				var s = state;
				if (s == null) return;
				var v = s.variantOf(context.CommonCache.getCacheSign(com), path);
				if (v == null || !s.load(v)) return;
				if (v.monos.length > 4) s.readers.push({com: com, reader: reader, monos: v.monos});
			}
			var typeModule = typing.TypeloadCacheHook.typeModuleHook;
			typing.TypeloadCacheHook.typeModuleHook = function(com, delay, path, p) {
				var s = state;
				if (s != null && (s.creating.length > 0 || s.building.length > 0)) s.cycleGuard(com, path);
				var r = typeModule(com, delay, path, p);
				var s = state;
				if (s != null) s.restoreMonos();
				return r;
			}
			var inner = typing.TypeloadParse.parseHook;
			typing.TypeloadParse.parseHook = function(com, rfile, p) {
				var s = state;
				if (s == null) return inner(com, rfile, p);
				var file = core.Path.getFullPath(rfile.file);
				s.note(file);
				var pk = (com.isMacroContext ? 1 : 0) + "\x00" + file;
				var main = sys.thread.Thread.current() == mainThread;
				var prev = s.parsing;
				if (main) s.parsing = pk;
				var r = try inner(com, rfile, p) catch (e:Dynamic) {
					if (main) s.parsing = prev;
					throw e;
				}
				if (main) s.parsing = prev;
				// (its interface hashed now: the declarations are not kept, a
				// large part of the build's memory until the store is written)
				mutex.acquire();
				var known = s.ifaces.exists(pk);
				mutex.release();
				if (!known) {
					var t0 = haxe.Timer.stamp();
					var h = switch r {
						case ParseSuccess(data, _): try ModuleInterface.hash(data.declarations) catch (_:Dynamic) null;
						case _: null;
					};
					mutex.acquire();
					s.ifaces.set(pk, h);
					s.ifaceTime += haxe.Timer.stamp() - t0;
					mutex.release();
				}
				return r;
			}
		}
		// (before the compiler's own: registrations from now until typing is
		// done are the macros')
		com.callbacks.addAfterSave(() -> capture(com));
		// (registered by a macro run in the typing of a module: state that
		// module's macros keep, typed every build; else the build is not kept)
		com.callbacks = new WatchedCallbacks(com.callbacks, com, what -> {
			if (s.typingStack.length > 0) {
				mutex.acquire();
				s.liveState.push({maker: s.typingStack[s.typingStack.length - 1], path: "Context." + what});
				mutex.release();
			} else if (s.volatileReason == null) s.volatileReason = what;
		});
	}

	static function stats():Bool
		return Sys.getEnv("HXMC_STATS") == "1";

	static function ms(t:Float):Int
		return Std.int((haxe.Timer.stamp() - t) * 1000);

	// Define.readHook: a define read (by the compiler, or by a macro through
	// Common.externalDefinesHook first)
	static function onRead(ctx:core.Define.DefineContext, key:String) {
		var s = state;
		if (s == null) {
			if (hookCalls > 0) return;
			mutex.acquire();
			var e = null;
			for (x in early)
				if (x.ctx == ctx) e = x;
			if (e == null) early.push(e = {ctx: ctx, keys: new Map()});
			e.keys.set(key, true);
			mutex.release();
			return;
		}
		s.read(ctx, key);
	}

	// Common.externalDefinesHook: a macro reads (a null key: all) or writes a define
	static function onExternal(com:CommonContext, name:Null<String>, write:Bool) {
		var s = state;
		if (s == null) return;
		if (write) {
			if (!s.captured && s.volatileReason == null) s.volatileReason = "a macro defines " + name;
			return;
		}
		var m = try macros.eval.EvalContext.getCtx().curapi.currentModule() catch (_:Dynamic) null;
		if (m == null) return;
		var role = s.roleOfSign(m.mExtra.mSign);
		if (role < 0) return;
		var role0 = com == s.com ? 0 : 1;
		mutex.acquire();
		var rk = role + "|" + key(m.mPath);
		var l = s.moduleReads.get(rk);
		if (l == null) s.moduleReads.set(rk, l = new Map());
		l.set(role0 + "\x00" + (name == null ? "*" : name), true);
		s.skipKey = name;
		mutex.release();
	}

	// TyperEntry.createdHook (before the typer loads anything): the
	// program's typer, then the macros' context's modules (the context its
	// macros run in, or the one it will create, with the defines the program
	// has now)
	static function onTyper(ctx:context.Typecore.Typer) {
		typers.push({com: ctx.com, g: ctx.g});
		wrapTypeExpr();
		var s = state;
		if (s == null) return;
		if (ctx.com == s.com && s.macroPending) {
			s.macroPending = false;
			var macros = ctx.g.macros;
			if (macros != null) {
				s.signs[1] = context.CommonCache.getCacheSign(macros.typer.com);
				s.defs[1] = macros.typer.com.defines.values;
			} else {
				var p = try predictMacroDefines(s.com) catch (_:Dynamic) null;
				if (p != null) {
					s.signs[1] = p.sign;
					s.defs[1] = p.values;
				}
			}
			var t0 = haxe.Timer.stamp();
			s.register(0);
			if (s.signs[1] != null) s.register(1);
			s.reselect();
			s.loaded = s.install(0);
			if (s.signs[1] != null) s.loaded += s.install(1);
			if (stats())
				Sys.println('hxmc: module cache: ${s.loaded} modules of ${s.index.variants.length} variants read (${Std.int((s.openTime + haxe.Timer.stamp() - t0) * 1000)} ms)');
			return;
		}
		if (ctx.com.isMacroContext && ctx.com == s.com.getMacros() && !s.macroPending) {
			var sign = context.CommonCache.getCacheSign(ctx.com);
			if (sign != s.signs[1]) {
				if (s.volatileReason == null) s.volatileReason = "the macros' context has other defines than predicted";
				if (stats()) Sys.println("hxmc: module cache: the macros' context's signature " + sign + " is not the predicted " + s.signs[1]);
				if (s.log) {
					var a = ctx.com.defines.values, p = s.defs[1];
					for (k in a.keys())
						if (p == null || p.get(k) != a.get(k)) Sys.println("hxmc: module cache:   " + k + "=" + a.get(k) + " predicted " + (p == null ? null : p.get(k)));
					if (p != null)
						for (k in p.keys())
							if (!a.exists(k)) Sys.println("hxmc: module cache:   " + k + " predicted " + p.get(k) + ", absent");
				}
			}
		}
	}

	static function typerOf(com:CommonContext):Null<context.Typecore.TyperGlobals> {
		var i = typers.length;
		while (i-- > 0)
			if (typers[i].com == com) return typers[i].g;
		return null;
	}

	// ServerCache.loadDirtyModuleHook: a module typed again under one restored
	static function loadDirty(com:CommonContext, path:GlobalTypePath, p:core.Globals.Pos):Null<ModuleDef> {
		var s = state;
		if (s == null) return null;
		var g = typerOf(com);
		if (g == null) return null;
		s.typedUnder++;
		if (s.log) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(path) + " typed again under a restored module");
		return typing.TypeloadModule.loadModulePrime(com, g, path, p);
	}

	// ServerCache.readerFindModuleHook: a module of the store a reader reaches
	// from the one it reads (a type its declarations or expressions name),
	// checked as one the typer loads (the checks of the module read leave its
	// dependencies out: partial typing): not decoded as the variant chosen
	// is, which may be one typed with other defines in a dependency (an
	// inline function of another variant of an imported module, inlined)
	static function onReaderFind(com:CommonContext, path:GlobalTypePath):Null<ModuleSkipReason> {
		var s = state;
		if (s == null) return null;
		var v = s.variantOf(context.CommonCache.getCacheSign(com), path);
		if (v == null || v.mc == null) return null;
		var mc = try context.CommonCache.getCache(com).getHxbModule(path) catch (_:Dynamic) null;
		if (mc == null) return null;
		return ServerCache.checkModule(com.sctx, com, path, mc.mcExtra, core.Globals.nullPos);
	}

	// ServerCache.dependencyDirtyHook: a module checked good by its
	// dependencies' hashes stays good
	static function onDependencyDirty(com:CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra, dep:ModuleDep, reason:ModuleSkipReason):Bool {
		var s = state;
		if (s == null) return false;
		var role = s.roleOfSign(mExtra.mSign);
		return role >= 0 && s.approved.exists(role + "|" + key(mPath));
	}

	// the macros' context's defines, as MacroContext.createMacroContext
	// makes them
	static function predictMacroDefines(com:CommonContext):{sign:String, values:haxe.ds.StringMap<String>} {
		var c = Common.clone(com, true);
		var d = Common.adaptDefinesToMacroContext(c.defines);
		c.defines.values = d.values;
		c.defines.definesSignature = null;
		// (-D hxmc.mir-macros: the platform the hook sets up, interp.MirMacros)
		if (typing.MacroContext.macroPlatformHook != null) typing.MacroContext.macroPlatformHook(c) else {
			c.platform = core.Globals.Platform.Eval;
			Common.initPlatform(c);
		}
		return {sign: core.Define.getSignature(c.defines), values: c.defines.values};
	}

	// the store for this build: its index read, the variants that match put
	// in the server's cache
	static function open(com:CommonContext):Null<ModuleCacheState> {
		var root = CacheDir.root();
		if (root == null) return null;
		var t0 = haxe.Timer.stamp();
		var modules = root + "modules/";
		var dir = modules + CacheDir.toolStamp() + "/";
		var used = dir + "used";
		if (!FileSystem.exists(used) || CacheDir.now() - CacheDir.mtime(used) > CacheDir.USED_REFRESH)
			if (!CacheDir.touch(used)) return null;
		CacheDir.trim(modules, dir);
		var key = Fingerprint.hash(["hxmc-modules", Sys.getCwd(), Sys.getEnv("HAXE_STD_PATH"), com.classPaths.asStringList().join("\n")].join("\x00"));
		var s = new ModuleCacheState(dir, dir + key + ".idx", com);
		s.signs[0] = context.CommonCache.getCacheSign(com);
		s.defs[0] = com.defines.values;
		var mcom = com.getMacros();
		// the defines read so far
		for (e in early) {
			var role = e.ctx == com.defines ? 0 : mcom != null && e.ctx == mcom.defines ? 1 : -1;
			if (role >= 0)
				for (k in e.keys.keys())
					s.global.set(role + "\x00" + k, true);
		}
		var ix = try ModuleStore.readIndex(s.indexPath) catch (e:Dynamic) {
			if (stats()) Sys.println('hxmc: module cache: ${s.indexPath} unreadable ($e)');
			null;
		}
		if (ix != null) {
			// (ids only grow from build to build: far from the 32-bit limit the
			// store starts again from nothing)
			if (ix.moduleHigh > ID_LIMIT || ix.varHigh > ID_LIMIT) ix = null;
		}
		if (ix == null) ix = new StoreIndex();
		s.index = ix;
		if (ix.variants.length > 0) CacheDir.used(s.indexPath);
		@:privateAccess {
			if (core.TFunctions.moduleUid.load() < ix.moduleHigh) core.TFunctions.moduleUid.store(ix.moduleHigh);
			if (core.TFunctions.varUid.load() < ix.varHigh) core.TFunctions.varUid.store(ix.varHigh);
		}
		s.openTime = haxe.Timer.stamp() - t0;
		return s;
	}

	public static function key(p:GlobalTypePath):String
		return p.pack.join("/") + "|" + p.name;

	// the com whose context has this signature (the build's or its macros')
	public static function comFor(com:CommonContext, sign:String):Null<CommonContext> {
		if (context.CommonCache.getCacheSign(com) == sign) return com;
		var m = com.getMacros();
		if (m != null && context.CommonCache.getCacheSign(m) == sign) return m;
		return null;
	}

	// the file a module's path resolves to in this com (null: none)
	public static function resolve(com:CommonContext, path:GlobalTypePath):Null<core.ClassPaths.ResolvedFile>
		return try typing.TypeloadParse.resolveModuleFile(com, path, {value: path.pack.copy()}, core.Globals.nullPos) catch (_:Dynamic) null;

	// whether the module's path resolves to its file in this com
	static function resolvesTo(com:CommonContext, path:GlobalTypePath, fileKey:String):Bool {
		var r = resolve(com, path);
		return r != null && com.partScope.fileKeys.get(core.Path.getFullPath(r.file)) == fileKey;
	}

	public static function size(file:String):Float
		return try FileSystem.stat(file).size catch (_:Dynamic) -1;

	// ServerCache.checkModuleHook: a module from the store, before the
	// server's checks
	static function check(com:CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra):Null<ModuleSkipReason> {
		var s = state;
		if (s == null) return null;
		var role = s.roleOfSign(mExtra.mSign);
		if (role < 0) return null;
		var v = s.chosen[role].get(key(mPath));
		if (v == null) return null;
		var t0 = haxe.Timer.stamp();
		var r = verify(com, s, v, mPath, mExtra);
		s.checked++;
		if (r == null) {
			s.approved.set(v.roleKey(), true);
			for (c in v.macroState) {
				var l = s.restoredState.get(c);
				if (l == null) s.restoredState.set(c, l = []);
				l.push(v.roleKey());
			}
		}
		if (s.log) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(mPath) + (r == null ? " good" : " dirty: " + core.TPrinting.Printer.sModuleSkipReason(r)));
		s.checkTime += haxe.Timer.stamp() - t0;
		return r;
	}

	static function verify(com:CommonContext, s:ModuleCacheState, v:Variant, mPath:GlobalTypePath, mExtra:ModuleDefExtra):Null<ModuleSkipReason> {
		var file = core.Path.UniqueKey.lazyPath(mExtra.mFile);
		if (!v.matched) return FileChanged(file + " (" + s.mismatch(v) + ")");
		if (noCache(s, mPath, file)) return FileChanged(file + " (-D hxmc.no-cache)");
		// (its macros kept state, for other modules' macros too: restored
		// while no macro of this build uses that state, else typed again;
		// "!": typed every build, its macros' results change from run to run)
		for (c in v.macroState)
			if (StringTools.startsWith(c, "!"))
				return FileChanged(file + " (" + c.substr(StringTools.startsWith(c, "!!") ? 2 : 1) + ", every build)");
		for (c in v.macroState)
			if (StringTools.startsWith(c, "Context.") || s.retype.exists(c) || s.touched.exists(c))
				return FileChanged(file + " (its macros keep state in " + c + ", " + (StringTools.startsWith(c, "Context.") ? "every build" : "used by this build's macros") + ")");
		switch mExtra.mKind {
			case MCode | MMacro:
				// (a module of the macros' context checked from the program's
				// before that context exists: its class paths are not known
				// yet, only its file is checked)
				var rcom = comFor(com, mExtra.mSign);
				if (rcom != null && !resolvesTo(rcom, mPath, core.Path.UniqueKey.lazyKey(mExtra.mFile))) return Shadowed(file);
			case MFake | MImport:
			case MExtern:
				return LibraryChanged;
		}
		var time = Common.fileTime(file);
		if (time == 0 && !FileSystem.exists(file)) {
			// (a @:generic instance: a type path for a file, checked by its dependencies)
			if (!(mExtra.mKind == MFake && v.mtime == 0)) return FileChanged(file);
		} else {
			var f = v.fileRec;
			if (f == null) return FileChanged(file);
			if (!(f.mtime == time && f.size == size(file)) && s.fileHash(file) != f.hash) return FileChanged(file);
			mExtra.mTime = time;
		}
		// (dependencies the store did not keep: the server could not find them)
		for (d in mExtra.mDeps) {
			var found = try {
				com.cs.getContext(d.mdSign).findModuleExtra(d.mdPath);
				true;
			} catch (_:core.ds.NotFound) false;
			if (!found) return DependencyDirty(d.mdPath, LibraryChanged);
		}
		// the dependencies as they were when it was typed: their interface,
		// or their whole content
		for (d in v.deps)
			if (s.depHash(d) != d.expect) return DependencyDirty(d.path, FileChanged(d.eligible ? "(interface)" : "(content)"));
		if (mExtra.mKind != MImport && !s.load(v)) return LibraryChanged;
		return null;
	}

	// the compiler's pool, also under -D disable-parallelism (the capture
	// only reads the typed program; each module's encoding is its own)
	static function parallel<A>(com:CommonContext, f:Null<core.ds.TaskPool>->A):A {
		var was = context.Parallel.enable;
		context.Parallel.enable = true;
		return try {
			var r = context.Parallel.runWithPool(com.sctx.pool, f);
			context.Parallel.enable = was;
			r;
		} catch (e:Dynamic) {
			context.Parallel.enable = was;
			throw e;
		}
	}

	// after the state is saved (before DCE and generation change the typed
	// program): the modules of the build as the server would cache them
	static function capture(com:CommonContext) {
		var s = state;
		if (s == null) return;
		s.captured = true;
		var t0 = haxe.Timer.stamp();
		// (the files and environment the macros read, as they are now)
		s.macroValues = new Map();
		{
			var mcom = com.getMacros();
			var cs = mcom != null && context.CommonCache.getCacheSign(mcom) == s.signs[1] ? [com, mcom] : [com];
			for (c in cs)
				for (m in c.modules)
					if ((m.mExtra.mKind == MCode || m.mExtra.mKind == MMacro) && s.restored(m) == null) s.typedCount++;
		}
		{
			var mcom = com.getMacros();
			fixMarks(s, mcom != null && context.CommonCache.getCacheSign(mcom) == s.signs[1] ? [com, mcom] : [com]);
		}
		// (a mark the store could not give back to its maker)
		if (s.unattributedMarks > 0 && s.volatileReason == null) s.volatileReason = s.unattributedMarks + " structural marks made outside the typing of a module";
		var stateful = stateMakers(s);
		for (l in stateful)
			for (c in l)
				if (StringTools.startsWith(c, "!")) s.volatileCount++;
		if (s.volatileReason != null) return;
		if (Common.hasErrorToReport(com)) {
			s.volatileReason = "errors";
			return;
		}
		// (and the macros' context's, when it is the one predicted: not a
		// context only an init macro used)
		var mcom = com.getMacros();
		var coms = [com];
		if (mcom != null && context.CommonCache.getCacheSign(mcom) == s.signs[1]) coms.push(mcom);
		// (every module restored, none processed again: the variants the
		// store has, the index as it is)
		var same = true;
		for (c in coms) {
			for (m in c.modules) {
				var old = m.mExtra.mKind == MExtern ? null : s.restored(m);
				if (m.mExtra.mKind != MExtern && (old == null || m.mExtra.mProcessed != old.processed)) {
					same = false;
					break;
				}
			}
			if (!same) break;
		}
		if (same) {
			s.captureTime = haxe.Timer.stamp() - t0;
			return;
		}
		// the defines the compiler read in this build, with their values
		var buildReads:Array<Read> = [];
		for (k in s.global.keys()) {
			var i = k.indexOf("\x00");
			var role = Std.parseInt(k.substr(0, i));
			var name = k.substr(i + 1);
			buildReads.push({role: role, name: name, value: s.value(role, name)});
		}
		buildReads.sort((a, b) -> Reflect.compare(a.role + a.name, b.role + b.name));
		var jobs:Array<{v:Variant, f:Void->{chunks:CachedChunks, monos:Bytes}}> = [];
		var all:Array<Variant> = [];
		var byKey = [new Map<String, Variant>(), new Map<String, Variant>()];
		for (role in 0...coms.length) {
			var c = coms[role];
			var config:compiler.hxb.HxbWriterConfig.WriterTargetConfig = switch c.hxbWriterConfig {
				case null: new compiler.hxb.HxbWriterConfig.WriterTargetConfig();
				case config: c.isMacroContext ? config.macroConfig : config.targetConfig;
			}
			function warn(w:core.Message.WarningCode, msg:String, p:core.Globals.Pos):Void c.warning(w, c.warningOptions, msg, p);
			var optimize = c.defines.values.exists(core.Define.AnalyzerOptimize);
			for (m in c.modules) {
				var x = m.mExtra;
				inline function skip(why:String)
					if (s.log) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(m.mPath) + " not kept (" + why + ")");
				if (x.mKind == MExtern) {
					skip("kind");
					continue;
				}
				// (two types with one path: an abstract whose implementation class
				// @:native gave the abstract's path, processed in the macros'
				// context, eval's mbedtls.SslAuthmode; HXB names a type by its
				// module and name, so read back one would stand for the other)
				if (m.mTypes.length > 1) {
					var names = new Map<String, Bool>(), twice = false;
					for (t in m.mTypes) {
						var n = core.Globals.sTypePath(core.TFunctions.tInfos(t).mtPath);
						if (names.exists(n)) twice = true;
						names.set(n, true);
					}
					if (twice) {
						skip("two types with one path");
						continue;
					}
				}
				var file = core.Path.UniqueKey.lazyPath(x.mFile);
				var time = Common.fileTime(file);
				var rec:Null<StoredFile> = null;
				if (time == 0 && !FileSystem.exists(file)) {
					if (!(x.mKind == MFake && x.mTime == 0)) {
						skip("no file");
						continue;
					}
				} else {
					// (a file changed while the build ran, or a module from another file)
					if (time != x.mTime) {
						skip("file changed");
						continue;
					}
					if ((x.mKind == MCode || x.mKind == MMacro) && !resolvesTo(c, m.mPath, core.Path.UniqueKey.lazyKey(x.mFile))) {
						skip("path resolves elsewhere");
						continue;
					}
					// (the content as parsed, else as the store has it, else now)
					rec = s.parsed.get(core.Path.getFullPath(file));
					var old = s.restored(m);
					if (rec == null && old != null && old.fileRec != null && old.fileRec.mtime == time && old.fileRec.size == size(file))
						rec = old.fileRec;
					if (rec == null) rec = s.record(file);
					if (rec == null) {
						skip("unreadable");
						continue;
					}
				}
				var v = new Variant();
				v.role = role;
				v.path = m.mPath;
				v.key = key(m.mPath);
				v.id = m.mId;
				v.extra = ModuleStore.writeExtra(x);
				v.signs = s.signs.copy();
				v.kind = x.mKind;
				v.processed = x.mProcessed != 0 ? -1 : 0;
				v.mtime = x.mTime;
				v.file = file;
				v.fileRec = rec;
				v.matched = true;
				v.deps = [];
				var macroDefines = false;
				var ok = true;
				for (d in x.mDeps) {
					var r = s.signs.indexOf(d.mdSign);
					if (r < 0) {
						ok = false;
						break;
					}
					switch d.mdOrigin {
						case MDepFromMacroInclude | MDepFromMacroDefine: macroDefines = true;
						case _:
					}
					// (in the same context its interface stands for it, also for a
					// macro that looked at it; across contexts, a macro's module, its
					// whole content: its code runs)
					var eligible = r == role;
					v.deps.push({role: r, path: d.mdPath, key: key(d.mdPath), eligible: eligible, expect: ""});
				}
				if (!ok) {
					skip("a dependency of another context");
					continue;
				}
				v.deps.sort((a, b) -> Reflect.compare(a.role + "|" + a.key, b.role + "|" + b.key));
				var old = s.restored(m);
				if (old != null) {
					v.reads = old.reads;
					v.buildReads = old.buildReads;
					v.iface = old.iface;
				} else {
					var pk = role + "\x00" + core.Path.getFullPath(file);
					var reads:Array<Read> = [];
					var names = s.fileReads.get(pk);
					if (names != null)
						for (n in names.keys())
							reads.push({role: role, name: n, value: s.value(role, n)});
					var mr = s.moduleReads.get(role + "|" + v.key);
					// (its macros reading its own file, as the view package's markup
					// does: already what the module is checked by)
					var own = haxe.io.Path.normalize(core.Path.getFullPath(file));
					if (mr != null) {
						var any = false;
						for (k in mr.keys()) {
							var i = k.indexOf("\x00");
							var r = Std.parseInt(k.substr(0, i));
							var n = k.substr(i + 1);
							if (r == 3 && n.substr(n.indexOf(":") + 1) == own) continue;
							any = true;
							reads.push({role: r, name: n, value: s.value(r, n)});
						}
						if (!any) mr = null;
					}
					reads.sort((a, b) -> Reflect.compare(a.role + a.name, b.role + b.name));
					v.reads = reads;
					// (files and environment variables its macros read)
					var outside = false;
					for (r in reads)
						if (r.role >= 2) {
							outside = true;
							if (s.log)
								Sys.println("hxmc: module cache: " + core.Globals.sTypePath(m.mPath) + " reads "
									+ (r.role == 2 ? "environment variable " + r.name : r.name) + " (its macros)");
						}
					if (outside) s.readingCount++;
					v.buildReads = buildReads;
					var ifaceMode = (x.mKind == MCode || x.mKind == MMacro) && StringTools.endsWith(file, ".hx") && !macroDefines && mr == null
						&& !optimize && !macroBuilt(m);
					v.iface = null;
					v.ifacePk = ifaceMode ? pk : null;
					if (s.log && v.ifacePk == null && (x.mKind == MCode || x.mKind == MMacro))
						Sys.println("hxmc: module cache: " + core.Globals.sTypePath(m.mPath) + " kept whole (" + (!ifaceMode ? (macroDefines ? "macro-defined" : mr != null ? "macro reads" : optimize ? "analyzer-optimize" : macroBuilt(m) ? "built by a macro" : "file") : "no interface") + ")");
				}
				// (the structural marks its typing made: Marks)
				var made = s.madeMarks.get(m);
				v.marks = old != null ? old.marks : made == null ? [] : made;
				var st = old != null ? null : stateful.get(m);
				v.macroState = old != null ? old.macroState : st == null ? [] : st;
				// (@:hxmc.noCache: typed every build, its dependents with it)
				if (old == null && noCacheMeta(m) && !Lambda.exists(v.macroState, c -> StringTools.startsWith(c, "!"))) {
					v.macroState = v.macroState.concat(["!!@:hxmc.noCache"]);
					s.volatileCount++;
				}
				if (s.log)
					for (c in v.macroState)
						if (StringTools.startsWith(c, "!"))
							Sys.println("hxmc: module cache: " + core.Globals.sTypePath(m.mPath) + " typed every build ("
								+ c.substr(StringTools.startsWith(c, "!!") ? 2 : 1) + (StringTools.startsWith(c, "!!") ? ", its dependents with it" : "") + ")");
				if (s.log && noCache(s, m.mPath, file)) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(m.mPath) + " typed every build (-D hxmc.no-cache)");
				all.push(v);
				byKey[role].set(v.key, v);
				// restored and not processed again: the stored blob
				if (old != null && x.mProcessed == old.processed) {
					v.blob = old.blob;
					v.blobOff = old.blobOff;
					v.blobSize = old.blobSize;
					continue;
				}
				v.fresh = true;
				v.prev = old;
				var skeletons = old != null && old.skeletons != null ? old.skeletons : Skeletons.encode(s, x.mSign, m.mPath);
				if (x.mKind == MImport) {
					v.blobData = {chunks: [], monos: noMonos, skeletons: skeletons};
					continue;
				}
				if (s.log && old != null) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(m.mPath) + " encoded again (processed " + x.mProcessed + ")");
				// (as ContextCache.cacheHxbModule, with a writer that keeps what
				// HXB does not)
				v.skeletons = skeletons;
				jobs.push({
					v: v,
					f: function() {
						var w = new CheckingHxbWriter(config, warn, new typing.TanonIdentification<Dynamic>());
						w.writeModule(m);
						return {chunks: (w.getChunks() : CachedChunks), monos: w.monoModifiers()};
					}
				});
			}
		}
		// the fresh modules' interfaces (hashed as their files were parsed)
		for (v in all)
			if (v.ifacePk != null) v.iface = s.ifaces.get(v.ifacePk);
		var none:{v:Variant, r:{chunks:CachedChunks, monos:Bytes}} = {v: null, r: null};
		var done = parallel(com, function(pool) {
			return context.Parallel.ParallelArray.map(pool, function(j:{v:Variant, f:Void->{chunks:CachedChunks, monos:Bytes}}) return {v: j.v, r: j.f()}, jobs,
				none);
		});
		for (d in done) {
			d.v.blobData = {chunks: d.r.chunks, monos: d.r.monos, skeletons: d.v.skeletons};
			// (a restored module processed again, the same as stored: its blob)
			var o = d.v.prev;
			if (o != null && o.loaded && ModuleStore.blobLength(d.v.blobData) == o.blobSize
				&& ModuleStore.sameBlob({chunks: o.chunks, monos: o.monos, skeletons: o.skeletons}, d.v.blobData)) {
				d.v.blob = o.blob;
				d.v.blobOff = o.blobOff;
				d.v.blobSize = o.blobSize;
				d.v.blobData = null;
				d.v.fresh = false;
				s.written--;
			}
		}
		// (the new blobs: in this build's pack, named by a nonce, their
		// offsets set as it is written)
		var nonce = CacheDir.nonce();
		for (v in all)
			if (v.blobData != null) {
				v.blob = nonce;
				v.blobSize = ModuleStore.blobLength(v.blobData);
			}
		// (the modules of the store this build did not load, as they are)
		for (role in 0...2)
			for (k => v in s.chosen[role])
				if (!byKey[role].exists(k)) byKey[role].set(k, v);
		// the modules whose dependencies are all kept, with the hashes of
		// their dependencies
		var dropped = true;
		while (dropped) {
			dropped = false;
			for (v in all) {
				if (byKey[v.role].get(v.key) != v) continue;
				for (d in v.deps)
					if (!byKey[d.role].exists(d.key)) {
						byKey[v.role].remove(v.key);
						dropped = true;
						if (s.log) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(v.path) + " not kept (a dependency is not: " + d.role + " " + d.key + ")");
						break;
					}
			}
		}
		var kept = [for (v in all) if (byKey[v.role].get(v.key) == v) v];
		var closure = new Closure(s, (role, k) -> byKey[role].get(k), "!");
		for (v in kept)
			for (d in v.deps) {
				var w = byKey[d.role].get(d.key);
				d.expect = d.eligible ? closure.di(w) : closure.df(w);
			}
		s.kept = kept;
		s.written += jobs.length;
		// the new blobs written in this build's pack beside the rest of the
		// build (finish waits for it before the index names them), their bytes
		// let go once written
		var fresh = [for (v in kept) if (v.blobData != null) v];
		s.packBlobs = fresh.length;
		if (fresh.length > 0) {
			var lock = new sys.thread.Lock();
			s.packLock = lock;
			var dir = s.dir;
			sys.thread.Thread.create(function() {
				var ok = try ModuleStore.savePack(dir, nonce, fresh) catch (_:Dynamic) false;
				for (v in fresh)
					v.blobData = null;
				s.packOk = ok;
				lock.release();
			});
		}
		s.captureTime = haxe.Timer.stamp() - t0;
	}

	// whether a build macro made a type of the module (@:build, @:genericBuild,
	// or @:autoBuild on a class it extends or implements): its fields may
	// depend on its whole source (the macro reads the bodies)
	static function macroBuilt(m:ModuleDef):Bool {
		inline function has(meta:core.Ast.Metadata, l:Array<core.MetaList.StrictMeta>):Bool {
			var r = false;
			for (x in l)
				if (core.Meta.has(x, meta)) r = true;
			return r;
		}
		function inherited(c:Null<TClass>, depth:Int):Bool {
			if (c == null || depth > 64) return false;
			if (core.Meta.has(AutoBuild, c.clMeta)) return true;
			if (c.clSuper != null && inherited(c.clSuper.cls, depth + 1)) return true;
			for (i in c.clImplements)
				if (inherited(i.cls, depth + 1)) return true;
			return false;
		}
		for (t in m.mTypes)
			switch t {
				case TClassDecl(c):
					if (has(c.clMeta, [Build, AutoBuild, GenericBuild]) || inherited(c, 0)) return true;
				case TEnumDecl(e):
					if (has(e.eMeta, [Build])) return true;
				case TAbstractDecl(a):
					if (has(a.aMeta, [Build, GenericBuild])) return true;
				case TTypeDecl(_):
			}
		return false;
	}

	// the end of a build (code: its exit code): the index written when it changed
	public static function finish(code:Int) {
		var s = state;
		state = null;
		ServerCache.checkModuleHook = null;
		typing.Finalization.sortExprHook = null;
		if (s == null) {
			CacheDir.settle();
			return;
		}
		var t0 = haxe.Timer.stamp();
		ModuleStore.closePacks();
		if (s.packLock != null) s.packLock.wait();
		var blobs = 0;
		var wrote = false;
		if (code == 0 && s.volatileReason == null && s.kept != null && s.kept.length > 0) {
			// the build's modules, then the other variants (not those it
			// superseded: the same module with the same reads, typed with
			// the same defines, or the one it was restored from), at most
			// MAX_VARIANTS per module. (A variant typed with other defines
			// stays although its reads are the same: they are its own, and
			// another build's dependencies can make its typing another, as
			// -D hxmc.wasm-gc makes Std's, which reads no define of it.)
			var list = s.kept.copy();
			var count = new Map<String, Int>();
			var same = new Map<String, Bool>();
			inline function supersedes(v:Variant)
				return v.roleKey() + "\x00" + ModuleStore.readsKey(v.reads.concat(v.buildReads)) + "\x00" + v.signs[v.role];
			for (v in list) {
				count.set(v.roleKey(), 1);
				same.set(supersedes(v), true);
				var from = v.prev != null ? v.prev : v.fresh ? null : v;
				if (from != null) same.set(v.roleKey() + "\x00" + from.blob + "\x00" + from.blobOff, true);
			}
			for (v in s.index.variants) {
				var k = v.roleKey();
				if (same.exists(supersedes(v)) || same.exists(k + "\x00" + v.blob + "\x00" + v.blobOff)) continue;
				var n = count.exists(k) ? count.get(k) : 0;
				if (n >= MAX_VARIANTS) continue;
				count.set(k, n + 1);
				list.push(v);
			}
			var changed = list.length != s.index.variants.length;
			if (!changed)
				for (i in 0...list.length)
					if (list[i].fresh || list[i].roleKey() != s.index.variants[i].roleKey() || list[i].blob != s.index.variants[i].blob) {
						changed = true;
						break;
					}
			if (changed) {
				var ok = s.packOk;
				blobs = s.packBlobs;
				var ix = new StoreIndex();
				ix.moduleHigh = @:privateAccess core.TFunctions.moduleUid.load();
				ix.varHigh = @:privateAccess core.TFunctions.varUid.load();
				ix.variants = list;
				var tmp = s.indexPath + "." + CacheDir.nonce() + ".tmp";
				if (ok)
					wrote = try {
						var b = ModuleStore.writeIndex(ix);
						var was = try FileSystem.stat(s.indexPath).size catch (_:Dynamic) 0;
						File.saveBytes(tmp, b);
						if (CacheDir.replace(tmp, s.indexPath)) {
							CacheDir.wrote(b.length - was);
							true;
						} else false;
					} catch (e:Dynamic) {
						try FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
						false;
					}
			}
		}
		if (stats())
			Sys.println('hxmc: module cache: ${s.checked} checked (${Std.int(s.checkTime * 1000)} ms), ${s.written} modules encoded (${Std.int(s.captureTime * 1000)} ms), '
				+ '${s.typedUnder} typed again under restored ones, ${s.cycleTyped} with their cycle, interfaces ${Std.int(s.ifaceTime * 1000)} ms, $blobs blobs, index ${wrote ? "written" : "unchanged"} (${ms(t0)} ms), '
				+ '${s.typedCount} typed from source, ${s.volatileCount} every build, ${s.readingCount} reading files or the environment'
				+ (s.volatileReason != null ? ' (not written: ${s.volatileReason})' : ''));
		CacheDir.settle();
	}
}

// the hashes of modules' interfaces (di) and whole contents (df), with
// their dependencies', per strongly connected component (Tarjan's): over
// the variants a build restores (their files and defines now), or over the
// modules a build ends with (when it writes them)
class Closure {
	final s:ModuleCacheState;
	final node:(Int, String) -> Null<Variant>;
	final memo = new Map<String, {di:String, df:String, clean:Bool, scc:Int}>();
	var sccs = 0;
	final index = new Map<String, Int>();
	final low = new Map<String, Int>();
	final onStack = new Map<String, Bool>();
	final stack:Array<Variant> = [];
	var counter = 0;

	// what stands for a module the store does not have (never the same in
	// a check as when the hashes were written)
	final missing:String;

	public function new(s:ModuleCacheState, node:(Int, String) -> Null<Variant>, missing:String) {
		this.s = s;
		this.node = node;
		this.missing = missing;
	}

	public function di(v:Null<Variant>):String
		return v == null ? missing : get(v).di;

	public function df(v:Null<Variant>):String
		return v == null ? missing : get(v).df;

	// whether every module of its strongly connected component has the file
	// and defines it was typed with (a module typed again in a cycle with
	// restored ones would be referenced by them while it is typed: a cycle
	// is restored whole or typed again whole)
	public function clean(v:Variant):Bool
		return get(v).clean;

	// its strongly connected component's number
	public function scc(v:Variant):Int
		return get(v).scc;

	function get(v:Variant):{di:String, df:String, clean:Bool, scc:Int} {
		var h = memo.get(v.roleKey());
		if (h == null) {
			connect(v);
			h = memo.get(v.roleKey());
		}
		return h;
	}

	function connect(v:Variant) {
		var k = v.roleKey();
		index.set(k, counter);
		low.set(k, counter);
		counter++;
		stack.push(v);
		onStack.set(k, true);
		for (d in v.deps) {
			var w = node(d.role, d.key);
			if (w == null) continue;
			var wk = w.roleKey();
			if (memo.exists(wk)) continue;
			if (!index.exists(wk)) {
				connect(w);
				if (low.get(wk) < low.get(k)) low.set(k, low.get(wk));
			} else if (onStack.exists(wk)) {
				if (index.get(wk) < low.get(k)) low.set(k, index.get(wk));
			}
		}
		if (low.get(k) != index.get(k)) return;
		var members = [];
		while (true) {
			var w = stack.pop();
			onStack.remove(w.roleKey());
			members.push(w);
			if (w == v) break;
		}
		members.sort((a, b) -> Reflect.compare(a.roleKey(), b.roleKey()));
		var inside = new Map<String, Bool>();
		for (m in members)
			inside.set(m.roleKey(), true);
		var f = new StringBuf(), i = new StringBuf();
		var ineligibleInside = false;
		var clean = true;
		for (m in members) {
			if (clean && !s.ownClean(m)) clean = false;
			f.add(m.roleKey());
			f.add("\n");
			f.add(s.sFull(m));
			i.add(m.roleKey());
			i.add("\n");
			i.add(s.sIface(m));
			for (d in m.deps) {
				var w = node(d.role, d.key);
				if (w == null) {
					f.add("\n" + missing);
					i.add("\n" + missing);
				} else if (inside.exists(w.roleKey())) {
					f.add("\n~" + w.roleKey());
					i.add("\n~" + w.roleKey());
					if (!d.eligible) ineligibleInside = true;
				} else {
					var h = memo.get(w.roleKey());
					f.add("\n" + h.df);
					i.add("\n" + (d.eligible ? h.di : h.df));
				}
			}
			f.add("\n;");
			i.add("\n;");
		}
		var dfh = Fingerprint.hash("F" + f.toString());
		var dih = ineligibleInside ? dfh : Fingerprint.hash("I" + i.toString());
		// (and each member's dependencies as they were when it was typed: a
		// member typed again for its dependencies makes the cycle typed again)
		if (clean)
			for (m in members) {
				for (d in m.deps) {
					var w = node(d.role, d.key);
					var actual = w == null ? missing : inside.exists(w.roleKey()) ? (d.eligible ? dih : dfh) : {
						var h = memo.get(w.roleKey());
						d.eligible ? h.di : h.df;
					};
					if (actual != d.expect) {
						clean = false;
						break;
					}
				}
				if (!clean) break;
			}
		var n = sccs++;
		for (m in members)
			memo.set(m.roleKey(), {di: dih, df: dfh, clean: clean, scc: n});
	}
}

class ModuleCacheState {
	public var dir:String;
	public var indexPath:String;
	public var com:CommonContext;
	public var index:StoreIndex;
	// per role (0: the program's context, 1: the macros'), its signature and
	// defines (the macros': predicted while that context does not exist)
	public var signs:Array<Null<String>> = [null, null];
	public var defs:Array<Null<haxe.ds.StringMap<String>>> = [null, null];
	// per role, the variant restored for each module (ModuleCache.key)
	public var chosen = [new Map<String, Variant>(), new Map<String, Variant>()];
	public var approved = new Map<String, Bool>();
	public var hashes = new Map<String, String>();
	public var closure:Null<Closure> = null;
	// the defines read: by the compiler (role and name), while parsing a file
	// (role and file: names), by a module's macros (role|key: role and name)
	public var global = new Map<String, Bool>();
	public var fileReads = new Map<String, Map<String, Bool>>();
	public var moduleReads = new Map<String, Map<String, Bool>>();
	// the file being parsed (role and file), and the read a macro makes
	// through Common.externalDefinesHook (not the compiler's)
	public var parsing:Null<String> = null;
	public var skipKey:Null<String> = null;
	// per role and file, its interface as parsed (ModuleInterface; null: none)
	public var ifaces = new Map<String, Null<String>>();
	// a file's interface as parsed in this build (null: not parsed, or none)
	public function iface(pk:String):Null<String> {
		@:privateAccess ModuleCache.mutex.acquire();
		var h = ifaces.get(pk);
		@:privateAccess ModuleCache.mutex.release();
		return h;
	}
	// per module (signature and path), what the sort of the types walks of
	// its classes' fields, as typed in this build (Skeletons)
	public var skeletons = new Map<String, Map<String, Bytes>>();
	public var walked = new Map<String, Bool>();
	// the readers of restored modules whose monomorphs have modifiers
	public var readers:Array<{com:CommonContext, reader:compiler.hxb.HxbReader, monos:Bytes}> = [];
	public var volatileReason:Null<String> = null;
	public var captured = false;
	public var kept:Null<Array<Variant>> = null;
	// HXMC_MODULE_CACHE_LOG=1: each module checked, each not kept, each encoded again
	public var log = Sys.getEnv("HXMC_MODULE_CACHE_LOG") == "1";
	public var loaded = 0;
	public var checked = 0;
	public var written = 0;
	public var typedUnder = 0;
	public var checkTime = 0.0;
	public var ifaceTime = 0.0;
	public var captureTime = 0.0;
	// the pack of the build's new blobs, written beside the rest of the build
	public var packLock:Null<sys.thread.Lock> = null;
	public var packOk = true;
	public var packBlobs = 0;

	// the files parsed, as the parser read them (their date, size and
	// content hash)
	public var parsed = new Map<String, StoredFile>();

	public function new(dir:String, indexPath:String, com:CommonContext) {
		this.dir = dir;
		this.indexPath = indexPath;
		this.com = com;
	}

	public var macroPending = true;
	// the modules whose code is being typed (Typecore.typeExprRef), the
	// structural marks made (by the module being typed, null outside), per
	// module the marks it made (Marks)
	public var typingStack:Array<Dynamic> = [];
	public var liveMarks:Array<{maker:Null<Dynamic>, cf:TClassField}> = [];
	public var madeMarks = new haxe.ds.ObjectMap<ModuleDef, Array<String>>();
	public var unattributedMarks = 0;
	// the static variables of macro classes used by the macros run in the
	// typing of a module (Variant.macroState)
	public var liveState:Array<{maker:Dynamic, path:String}> = [];
	// the typers of the expressions being typed through typeExprRef, and the
	// depth of the typing stack each is at (ModuleCache.leakyCall)
	public var typerStack:Array<context.Typecore.Typer> = [];
	public var typerDepths:Array<Int> = [];
	// per module (role and key) whose macros' results change from run to run,
	// whether its dependents can copy them (ModuleCache.onVolatile)
	public var volatileMakers = new Map<String, Bool>();
	public var lastVolatileMaker:Null<Dynamic> = null;
	public var lastVolatileLeaky = false;
	// -D hxmc.no-cache's entries (ModuleCache.noCache)
	public var noCacheList:Null<Array<String>> = null;
	// the modules typed from their source, those typed every build
	public var typedCount = 0;
	public var volatileCount = 0;
	// the modules typed in this build whose macros read files or the environment
	public var readingCount = 0;
	public var lastStateMaker:Null<Dynamic> = null;
	public var lastStateClass:Null<TClass> = null;
	// the macro classes this build's macros used, the restored modules whose
	// macros kept state in each, the classes whose modules are typed
	// (HXMC_MODULE_CACHE_RETYPE, and those of edited modules)
	public var touched = new Map<String, Bool>();
	public var restoredState = new Map<String, Array<String>>();
	public var retype:Map<String, Bool> = {
		var m = new Map<String, Bool>();
		var e = Sys.getEnv("HXMC_MODULE_CACHE_RETYPE");
		if (e != null)
			for (c in e.split(","))
				if (c != "") m.set(c, true);
		m;
	};
	public var stdClass = new haxe.ds.ObjectMap<TClass, Bool>();
	var stdDirs:Null<Array<String>> = null;

	// whether the file is one of the std's (its class paths)
	public function isStdFile(file:String):Bool {
		if (stdDirs == null) {
			stdDirs = [];
			for (cp in com.classPaths.getStdPaths())
				if (cp.path != "")
					stdDirs.push(haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(try FileSystem.absolutePath(cp.path) catch (_:Dynamic) cp.path)));
		}
		var f = haxe.io.Path.normalize(try FileSystem.absolutePath(file) catch (_:Dynamic) file);
		for (d in stdDirs)
			if (StringTools.startsWith(f, d)) return true;
		return false;
	}
	// the cycles (Closure.scc) of the modules being typed from their source
	public var creating:Array<Int> = [];
	public var cycleTyped = 0;

	public function sccOf(v:Variant):Int {
		if (closure == null) closure = new Closure(this, (role, k) -> chosen[role].get(k), "?");
		return closure.scc(v);
	}

	// a restored module about to be loaded while a module of its cycle is
	// typed from its source: typed from its source too
	public function cycleGuard(com:CommonContext, path:GlobalTypePath) {
		var v = variantOf(context.CommonCache.getCacheSign(com), path);
		if (v == null || v.mc == null) return;
		// (the server's copy for this compilation)
		var mc = try context.CommonCache.getCache(com).getHxbModule(path) catch (_:Dynamic) null;
		if (mc == null) return;
		switch mc.mcExtra.mCacheState {
			case MSBad(_): return;
			case _:
		}
		if (creating.indexOf(sccOf(v)) < 0 && !refersToBuilding(v)) return;
		mc.mcExtra.mCacheState = MSBad(FileChanged(v.file + " (typed with a module of its cycle)"));
		cycleTyped++;
		if (log) Sys.println("hxmc: module cache: " + core.Globals.sTypePath(path) + " typed again with a module of its cycle");
	}
	public var openTime = 0.0;

	// the modules typed from their source whose classes are being built
	// (TypeloadModule.buildClassHook)
	public var building:Array<ModuleDef> = [];

	// whether a restored module depends on one whose class is being built,
	// or is of its cycle
	function refersToBuilding(v:Variant):Bool {
		for (m in building) {
			var role = roleOfSign(m.mExtra.mSign);
			if (role < 0) continue;
			var k = ModuleCache.key(m.mPath);
			for (d in v.deps)
				if (d.role == role && d.key == k) return true;
			var w = chosen[role].get(k);
			if (w != null && w.role == v.role && sccOf(w) == sccOf(v)) return true;
		}
		return false;
	}

	// the variants of a role that match the build's defines chosen: per
	// module, of those whose reads match, one whose file has the content it
	// has now (a file edited back), of those one typed with this build's
	// defines (the signature of its context), of those the newest; else the
	// newest (checked dirty). The reads of a module are its own (its file's
	// conditions, its macros'): one whose typing depends on defines through a
	// module it depends on (an inline function of a module whose file reads
	// -D hxmc.wasm-gc, inlined; the fields a build macro makes for the
	// target) has a variant per build that matches every such build, the one
	// typed with the build's defines the one whose dependencies are as they
	// were (the checks decide; reselect for a module a macro defined)
	public function register(role:Int) {
		var first = new Map<String, Variant>();
		var more = new Map<String, Array<Variant>>();
		var c = chosen[role];
		for (v in index.variants) {
			if (v.role != role) continue;
			if (!first.exists(v.key)) first.set(v.key, v);
			if (!matches(v)) continue;
			v.matched = true;
			var w = c.get(v.key);
			if (w == null) c.set(v.key, v) else {
				var l = more.get(v.key);
				if (l == null) more.set(v.key, l = [w]);
				l.push(v);
			}
		}
		for (k => l in more) {
			var v = c.get(k);
			// (the content its file has now)
			var h = v.file == null || v.fileRec == null ? null : {
				var time = Common.fileTime(v.file);
				v.fileRec.mtime == time && v.fileRec.size == ModuleCache.size(v.file) ? v.fileRec.hash : fileHash(v.file);
			}
			var best = v, rank = -1;
			for (w in l) {
				var r = (h != null && w.fileRec != null && w.fileRec.hash == h ? 2 : 0) + (w.signs[role] == signs[role] ? 1 : 0);
				if (r > rank) {
					best = w;
					rank = r;
				}
			}
			c.set(k, best);
		}
		for (k => v in first)
			if (!c.exists(k)) c.set(k, v);
		alternatives[role] = more;
		// (a module whose macros keep state, edited: typed, its macros use
		// that state, so the others whose macros keep it there are typed too)
		for (v in c)
			if (v.macroState.length > 0 && v.file != null && v.fileRec != null) {
				var time = Common.fileTime(v.file);
				if (v.fileRec.mtime == time && v.fileRec.size == ModuleCache.size(v.file)) continue;
				if (fileHash(v.file) == v.fileRec.hash) continue;
				for (x in v.macroState)
					retype.set(x, true);
			}
	}

	// per role, the variants whose reads match, per module that has several
	var alternatives:Array<Map<String, Array<Variant>>> = [new Map(), new Map()];

	// a module without a file of its own, which a macro defined: of its
	// variants, one whose dependencies are as they were when it was typed
	// (the one typed with the variant restored for the module whose macro
	// defines it, which, restored, does not define it again)
	public function reselect() {
		for (role in 0...2)
			for (k => l in alternatives[role]) {
				var c = chosen[role];
				var v = c.get(k);
				if (v == null || v.fileRec != null || (v.file != null && v.file != "" && FileSystem.exists(v.file)) || depsMatch(v)) continue;
				for (w in l) {
					if (w == v || w.fileRec != null) continue;
					c.set(k, w);
					closure = null;
					if (depsMatch(w)) {
						v = w;
						break;
					}
				}
				c.set(k, v);
				closure = null;
			}
	}

	// the chosen variants of a role put in the server's cache; the number
	// of modules
	public function install(role:Int):Int {
		var c = chosen[role];
		var cc = com.cs.getContext(signs[role]);
		var hxb = cc.getHxb();
		var n = 0;
		for (v in c) {
			var x = ModuleStore.readExtra(v.extra);
			x.mSign = signs[role];
			for (d in x.mDeps) {
				var r = v.signs.indexOf(d.mdSign);
				if (r >= 0 && signs[r] != null) d.mdSign = signs[r];
			}
			v.x = x;
			if (x.mKind == MImport) {
				// (an import.hx: no types, kept as a module in memory, as the server does)
				cc.cacheModuleInMemory(v.path, ({mId: v.id, mPath: v.path, mTypes: [], mStatics: null, mExtra: x} : ModuleDef));
			} else {
				var mc:compiler.hxb.HxbData.ModuleCache = {
					mcPath: v.path,
					mcId: v.id,
					mcChunks: [],
					mcExtra: x
				};
				v.mc = mc;
				hxb.replace(v.path, mc);
			}
			n++;
		}
		return n;
	}

	// whether a variant's dependencies have the hashes they had when it was
	// typed
	function depsMatch(v:Variant):Bool {
		for (d in v.deps)
			if (depHash(d) != d.expect) return false;
		return true;
	}

	public function roleOfSign(sign:String):Int
		return sign == signs[0] ? 0 : sign != null && sign == signs[1] ? 1 : -1;

	public function comOf(role:Int):Null<CommonContext> {
		if (role == 0) return com;
		var m = com.getMacros();
		return m != null && context.CommonCache.getCacheSign(m) == signs[1] ? m : null;
	}

	// the variant restored for a module of the context with this signature
	public function variantOf(sign:String, path:GlobalTypePath):Null<Variant> {
		var role = roleOfSign(sign);
		return role < 0 ? null : chosen[role].get(ModuleCache.key(path));
	}

	// the variant a module of the build was restored from (null: typed)
	public function restored(m:ModuleDef):Null<Variant> {
		var v = variantOf(m.mExtra.mSign, m.mPath);
		return v != null && v.id == m.mId && (v.mc != null || v.kind == MImport) ? v : null;
	}

	// a define read in a defines context (Define.readHook)
	// (the build's reads per role, as global has them: a define read again
	// costs a lookup)
	final seen = [new Map<String, Bool>(), new Map<String, Bool>()];

	public function read(ctx:core.Define.DefineContext, key:String) {
		var role = ctx == com.defines ? 0 : -1;
		if (role < 0) {
			var m = com.getMacros();
			if (m != null && ctx == m.defines) role = 1 else return;
		}
		@:privateAccess ModuleCache.mutex.acquire();
		if (skipKey != null && skipKey == key) {
			skipKey = null;
		} else if (parsing != null && sys.thread.Thread.current() == @:privateAccess ModuleCache.mainThread) {
			var l = fileReads.get(parsing);
			if (l == null) fileReads.set(parsing, l = new Map());
			l.set(key, true);
		} else if (!seen[role].exists(key)) {
			seen[role].set(key, true);
			global.set(role + "\x00" + key, true);
		}
		@:privateAccess ModuleCache.mutex.release();
	}

	// a role's defines now (the macros': their context's once it exists)
	function defsNow(role:Int):Null<haxe.ds.StringMap<String>> {
		if (role == 0) return com.defines.values;
		var m = com.getMacros();
		if (m != null && m.defines.values != defs[1]) {
			if (context.CommonCache.getCacheSign(m) == signs[1]) defs[1] = m.defines.values;
		}
		return defs[1];
	}

	// a define's value in a role now (null: not defined); "*": all of them
	public function value(role:Int, name:String):Null<String> {
		if (role >= 2) {
			var k = role + "\x00" + name;
			if (macroValues.exists(k)) return macroValues.get(k);
			var x = role == 2 ? envValue(name) : fileValue(name);
			macroValues.set(k, x);
			return x;
		}
		var d = defsNow(role);
		if (d == null) return "?";
		if (name == "*") {
			var ks = [for (k in d.keys()) k];
			ks.sort(Reflect.compare);
			return Fingerprint.hash([for (k in ks) k + "=" + d.get(k)].join("\n"));
		}
		return d.get(name);
	}

	// the values of the macros' reads of files and of the environment (roles 2
	// and 3), computed once a build (again at the capture)
	public var macroValues = new Map<String, Null<String>>();

	// an environment variable's value ("*": the whole environment, without
	// hxmc's own variables)
	function envValue(name:String):Null<String> {
		if (name != "*") return Sys.getEnv(name);
		var env = Sys.environment();
		var ks = [for (k in env.keys()) if (!StringTools.startsWith(k, "HXMC_")) k];
		ks.sort(Reflect.compare);
		return Fingerprint.hash([for (k in ks) k + "=" + env.get(k)].join("\n"));
	}

	// what a macro saw of a file: kind:path (ModuleCache.onFileRead)
	function fileValue(name:String):Null<String> {
		var i = name.indexOf(":");
		var kind = name.substr(0, i), path = name.substr(i + 1);
		return try switch kind {
			case "c": CacheDir.hashBytes(File.getBytes(path));
			case "d":
				var l = FileSystem.readDirectory(path);
				l.sort(Reflect.compare);
				Fingerprint.hash(l.join("\n"));
			case "e": FileSystem.exists(path) ? (FileSystem.isDirectory(path) ? "dir" : "file") : null;
			case "s":
				var st = FileSystem.stat(path);
				st.mtime.getTime() + "/" + st.size + "/" + st.mode;
			case "p": FileSystem.fullPath(path);
			case _: null;
		} catch (_:Dynamic) null;
	}

	// why a variant does not match the build: its first read whose value differs
	public function mismatch(v:Variant):String {
		for (r in v.reads.concat(v.buildReads))
			if (value(r.role, r.name) != r.value)
				return switch r.role {
					case 2: "environment variable " + (r.name == "*" ? "(all)" : r.name) + ", read by a macro";
					case 3:
						var i = r.name.indexOf(":");
						(switch r.name.substr(0, i) {
							case "d": "directory listing ";
							case "e": "existence of ";
							case "s": "status of ";
							case "p": "full path of ";
							case _: "";
						}) + r.name.substr(i + 1) + ", read by a macro";
					case _: "define " + r.name;
				};
		return "defines";
	}

	final buildMatch = new haxe.ds.ObjectMap<Array<Read>, Bool>();
	final buildValues = new haxe.ds.ObjectMap<Array<Read>, String>();

	function readsMatch(l:Array<Read>):Bool {
		for (r in l)
			if (value(r.role, r.name) != r.value) return false;
		return true;
	}

	public function matches(v:Variant):Bool {
		if (!readsMatch(v.reads)) return false;
		var m = buildMatch.get(v.buildReads);
		if (m == null) buildMatch.set(v.buildReads, m = readsMatch(v.buildReads));
		return m;
	}

	function readsValues(l:Array<Read>):String {
		var b = new StringBuf();
		for (r in l) {
			b.add(r.role);
			b.add(r.name);
			b.add("=");
			var x = value(r.role, r.name);
			b.add(x == null ? "!" : x);
			b.add("\n");
		}
		return b.toString();
	}

	// (the values of a build's reads, hashed once)
	function buildValuesOf(l:Array<Read>):String {
		var h = buildValues.get(l);
		if (h == null) buildValues.set(l, h = Fingerprint.hash(readsValues(l)));
		return h;
	}

	public function fileHash(file:String):Null<String> {
		var h = hashes.get(file);
		if (h == null) {
			h = try CacheDir.hashBytes(File.getBytes(file)) catch (_:Dynamic) null;
			if (h != null) hashes.set(file, h);
		}
		return h;
	}

	// what stands for something not known now (never equal to anything)
	var unknowns = 0;

	// (with a nonce: never the same as a hash an earlier build kept)
	final nonce = CacheDir.nonce();

	function unknown():String
		return "?" + nonce + (unknowns++);

	// the content hash of a variant's file now ("-": none, "?": missing)
	function curFileHash(v:Variant):String {
		var file = v.file;
		if (file == null || file == "") return "-";
		var time = Common.fileTime(file);
		if (time == 0 && !FileSystem.exists(file)) return v.kind == MFake && v.mtime == 0 ? "-" : unknown();
		var f = v.fileRec;
		if (f != null && f.mtime == time && f.size == ModuleCache.size(file)) return f.hash;
		var h = fileHash(file);
		return h == null ? unknown() : h;
	}

	// a variant's interface now (its file parsed again where it changed or
	// its defines differ)
	function curIface(v:Variant):String {
		if (v.fileRec != null && v.matched && curFileHash(v) == v.fileRec.hash) return v.iface;
		var c = comOf(v.role);
		if (c == null) return unknown();
		var r = ModuleCache.resolve(c, v.path);
		if (r == null || core.Path.getFullPath(r.file) != core.Path.getFullPath(v.file)) return unknown();
		var pk = v.role + "\x00" + core.Path.getFullPath(v.file);
		@:privateAccess ModuleCache.mutex.acquire();
		var known = ifaces.exists(pk);
		@:privateAccess ModuleCache.mutex.release();
		if (!known) try typing.TypeloadParse.parseHook(c, r, core.Globals.nullPos) catch (_:Dynamic) {}
		var h = iface(pk);
		return h == null ? unknown() : h;
	}

	// what stands for a variant's whole content (with the defines the build
	// that typed it read: a macro's module runs its code), and for its
	// interface (its file's declarations as parsed now, or its content and
	// its own defines for a module typed with macros: not the build's, which
	// would make the same interface typed in two builds two)
	public function sFull(v:Variant):String {
		if (leaky(v)) return unknown();
		return Fingerprint.hash("full\n" + curFileHash(v) + "\n" + readsValues(v.reads) + buildValuesOf(v.buildReads));
	}

	// whether a variant's dependents can copy results of its macros that
	// change from run to run (or -D hxmc.no-cache names it): what stands for it
	// is new every build
	function leaky(v:Variant):Bool {
		for (c in v.macroState)
			if (StringTools.startsWith(c, "!!")) return true;
		return @:privateAccess ModuleCache.noCache(this, v.path, v.file);
	}

	public function sIface(v:Variant):String {
		if (leaky(v)) return unknown();
		if (v.iface == null) return Fingerprint.hash("own\n" + curFileHash(v) + "\n" + readsValues(v.reads));
		return Fingerprint.hash("iface\n" + curIface(v));
	}

	// whether a variant can be restored as it is: its defines and its file's content
	public function ownClean(v:Variant):Bool
		return v.matched && (v.fileRec == null ? curFileHash(v) == "-" : curFileHash(v) == v.fileRec.hash);

	public function sccClean(v:Variant):Bool {
		if (closure == null) closure = new Closure(this, (role, k) -> chosen[role].get(k), "?");
		return closure.clean(v);
	}

	// a dependency's hash now (its interface or its content)
	public function depHash(d:StoredDep):String {
		if (closure == null) closure = new Closure(this, (role, k) -> chosen[role].get(k), "?");
		var w = chosen[d.role].get(d.key);
		return d.eligible ? closure.di(w) : closure.df(w);
	}

	// a variant's blob read, its chunks given to the server's copy
	public function load(v:Variant):Bool {
		if (v.loaded) return true;
		if (!ModuleStore.loadBlob(dir, v)) return false;
		if (v.mc != null && v.mc.mcChunks.length == 0)
			for (c in v.chunks)
				v.mc.mcChunks.push(c);
		return true;
	}

	public function note(file:String)
		if (!parsed.exists(file)) {
			var r = record(file);
			if (r != null) parsed.set(file, r);
		}

	// a file's date, size and content hash; a date within RACY seconds of
	// now is not kept (a later change within the date's resolution would
	// not show): the next build compares the content
	public function record(file:String):Null<StoredFile> {
		var st = try FileSystem.stat(file) catch (_:Dynamic) return null;
		var b = try File.getBytes(file) catch (_:Dynamic) return null;
		var mtime = st.mtime.getTime() / 1000.0;
		return {mtime: CacheDir.now() - mtime < RACY ? -1 : mtime, size: b.length, hash: CacheDir.hashBytes(b)};
	}

	static inline var RACY = 3.0;

	// the modifiers back on the monomorphs of the modules read since
	public function restoreMonos() {
		var l = readers;
		readers = [];
		for (r in l)
			CheckingHxbWriter.restore(r.com, r.reader, r.monos);
	}
}

// the compiler's callbacks, telling when a macro registers one before
// typing is done (while a module is typed: a module restored later would not
// register it)
class WatchedCallbacks extends CompilerCallbacks {
	final com:CommonContext;
	final onEarly:String->Void;

	public function new(old:CompilerCallbacks, com:CommonContext, onEarly:String->Void) {
		super();
		this.com = com;
		this.onEarly = onEarly;
		@:privateAccess {
			beforeTyperCreate = old.beforeTyperCreate;
			afterInitMacros = old.afterInitMacros;
			afterTyping = old.afterTyping;
			beforeSave = old.beforeSave;
			afterSave = old.afterSave;
			afterFilters = old.afterFilters;
			afterGeneration = old.afterGeneration;
			nullSafetyReport = old.nullSafetyReport;
		}
	}

	function early(what:String)
		if (com.stage.getIndex() < CTypingDone.getIndex() && fromMacroApi()) onEarly(what);

	static var apiNames:Null<Array<Int>> = null;

	// whether Eval is running haxe.macro.Context's onGenerate, onAfterTyping
	// or onAfterGenerate (the compiler registers callbacks of its own while
	// typing, also in a macro: a forced inline call's check)
	static function fromMacroApi():Bool {
		var env = try macros.eval.EvalContext.getEval(null).env catch (_:Dynamic) null;
		if (env == null) return false;
		if (apiNames == null) {
			var h = macros.eval.EvalHash.hash;
			apiNames = [h("haxe.macro.Context"), h("onGenerate"), h("onAfterTyping"), h("onAfterGenerate")];
		}
		while (env != null) {
			switch env.envInfo.kind {
				case EKMethod(t, f) if (t == apiNames[0] && (f == apiNames[1] || f == apiNames[2] || f == apiNames[3])):
					return true;
				case _:
			}
			env = env.envParent;
		}
		return false;
	}

	override public function addAfterTyping(f:Array<ModuleType>->Void) {
		early("onAfterTyping");
		super.addAfterTyping(f);
	}

	override public function addBeforeSave(f:Void->Void) {
		early("onGenerate");
		super.addBeforeSave(f);
	}

	override public function addAfterSave(f:Void->Void) {
		early("onGenerate");
		super.addAfterSave(f);
	}

	override public function addAfterFilters(f:Void->Void) {
		early("afterFilters");
		super.addAfterFilters(f);
	}

	override public function addAfterGeneration(f:Void->Void) {
		early("onAfterGenerate");
		super.addAfterGeneration(f);
	}

	override public function addNullSafetyReport(f:NullSafetyReportCallback) {
		early("nullSafetyReport");
		super.addNullSafetyReport(f);
	}
}

// the server's HXB writer, keeping what HXB does not of the module's unbound
// monomorphs: their modifiers (a Null<Unknown> read back would be a plain
// monomorph, and the program after it could differ). Per monomorph with
// modifiers: its index in the module's table, then the modifiers (0
// MNullable, 1 MOpenStructure, 2 MDynamic).
class CheckingHxbWriter extends compiler.hxb.HxbWriter {
	public function monoModifiers():Bytes {
		var o = new BytesOutput();
		var items = @:privateAccess tmonos.toList();
		var n = 0;
		for (it in items)
			if (it.key.tmModifiers.length > 0) n++;
		o.writeInt32(n);
		for (i in 0...items.length) {
			var mods = items[i].key.tmModifiers;
			if (mods.length == 0) continue;
			o.writeInt32(i);
			o.writeByte(mods.length);
			for (m in mods)
				o.writeByte(switch m {
					case MNullable(_): 0;
					case MOpenStructure: 1;
					case MDynamic: 2;
				});
		}
		return o.getBytes();
	}

	// the modifiers back on the monomorphs a reader made (after it read the module)
	public static function restore(com:CommonContext, reader:compiler.hxb.HxbReader, b:Bytes) {
		var i = new BytesInput(b);
		var monos:Array<T> = @:privateAccess reader.tmonos;
		for (_ in 0...i.readInt32()) {
			var index = i.readInt32();
			var mods = [
				for (_ in 0...i.readByte()) switch i.readByte() {
					case 0: MNullable(com.basic.tnull);
					case 1: MOpenStructure;
					case _: MDynamic;
				}
			];
			switch index < monos.length ? monos[index] : null {
				case TMono(r):
					r.tmModifiers = mods;
				case _:
			}
		}
	}
}

// What the sort of the types (Finalization.sortTypes) walks of a class's
// fields, kept per module: a module restored from the store has its
// expressions as the filters left them, and the sort must walk what it saw
// when the module was typed (the order of the types, and so the program's
// type numbering, follows it). Per expression (a class's init, a static
// field, the constructor), the walk's events in order: a type expression
// (0, its kind, module and name), a construction (1, the class), a static
// field (2, the class and field). Played back as a block of those
// expressions, the walk does the same.
class Skeletons {
	static function moduleKey(sign:String, p:GlobalTypePath):String
		return sign + "\x00" + ModuleCache.key(p);

	static function restoredEntry(s:ModuleCacheState, m:ModuleDef):Null<ModuleStore.Variant>
		return s.restored(m);

	static function typeRef(o:BytesOutput, m:ModuleDef, name:String) {
		ModuleStore.path(o, m.mPath);
		ModuleStore.str(o, name);
	}

	static function record(e:TExpr):Bytes {
		var o = new BytesOutput();
		function rec(e:TExpr)
			switch e.eexpr {
				case TTypeExpr(t):
					o.writeByte(0);
					o.writeByte(switch t {
						case TClassDecl(_): 0;
						case TEnumDecl(_): 1;
						case TAbstractDecl(_): 2;
						case TTypeDecl(_): 3;
					});
					var i = core.TFunctions.tInfos(t);
					typeRef(o, i.mtModule, i.mtPath.name);
				case TNew(c, _, _):
					core.Texpr.iter(rec, e);
					o.writeByte(1);
					typeRef(o, c.clModule, c.clPath.name);
				case TField(e1, FStatic(c, cf)):
					rec(e1);
					o.writeByte(2);
					typeRef(o, c.clModule, c.clPath.name);
					ModuleStore.str(o, cf.cfName);
				case _:
					core.Texpr.iter(rec, e);
			}
		rec(e);
		return o.getBytes();
	}

	static function computeClass(s:ModuleCacheState, c:TClass) {
		var mk = moduleKey(c.clModule.mExtra.mSign, c.clModule.mPath);
		var ck = mk + "\x00" + c.clPath.name;
		if (s.walked.exists(ck)) return;
		s.walked.set(ck, true);
		var map = s.skeletons.get(mk);
		if (map == null) s.skeletons.set(mk, map = new Map());
		var init = core.TOther.TClassTools.getClInit(c);
		if (init != null) map.set(c.clPath.name + "\x00", record(init));
		for (cf in c.clStatics)
			if (cf.cfExpr != null) map.set(c.clPath.name + "\x00" + cf.cfName, record(cf.cfExpr));
		if (c.clConstructor != null && c.clConstructor.cfExpr != null) map.set(c.clPath.name + "\x00new", record(c.clConstructor.cfExpr));
	}

	// the classes of the modules this build typed (not restored)
	public static function computeAll(com:CommonContext) {
		var s = ModuleCache.current();
		if (s == null) return;
		var key = "com:" + context.CommonCache.getCacheSign(com);
		if (s.walked.exists(key)) return;
		s.walked.set(key, true);
		// (the walks recorded in parallel: each reads its own expression)
		var work:Array<{map:Map<String, Bytes>, name:String, e:TExpr}> = [];
		com.moduleLut.iter(function(_, m) {
			if (restoredEntry(s, m) != null) return;
			for (t in m.mTypes)
				switch t {
					case TClassDecl(c):
						var mk = moduleKey(c.clModule.mExtra.mSign, c.clModule.mPath);
						var ck = mk + "\x00" + c.clPath.name;
						if (s.walked.exists(ck)) continue;
						s.walked.set(ck, true);
						var map = s.skeletons.get(mk);
						if (map == null) s.skeletons.set(mk, map = new Map());
						var init = core.TOther.TClassTools.getClInit(c);
						if (init != null) work.push({map: map, name: c.clPath.name + "\x00", e: init});
						for (cf in c.clStatics)
							if (cf.cfExpr != null) work.push({map: map, name: c.clPath.name + "\x00" + cf.cfName, e: cf.cfExpr});
						if (c.clConstructor != null && c.clConstructor.cfExpr != null)
							work.push({map: map, name: c.clPath.name + "\x00new", e: c.clConstructor.cfExpr});
					case _:
				}
		});
		var recorded = @:privateAccess ModuleCache.parallel(com, pool -> context.Parallel.ParallelArray.map(pool, w -> record(w.e), work, null));
		for (i in 0...work.length)
			work[i].map.set(work[i].name, recorded[i]);
	}

	// Finalization.sortExprHook
	public static function sortExpr(c:TClass, cf:Null<TClassField>, e:TExpr):TExpr {
		var s = ModuleCache.current();
		if (s == null) return e;
		var com = ModuleCache.comFor(s.com, c.clModule.mExtra.mSign);
		if (com != null) computeAll(com);
		var entry = restoredEntry(s, c.clModule);
		if (entry == null) return e;
		if (entry.skeletonMap == null) {
			if (entry.skeletons == null) return e;
			entry.skeletonMap = decode(entry.skeletons);
		}
		var b = entry.skeletonMap.get(c.clPath.name + "\x00" + (cf == null ? "" : cf == c.clConstructor ? "new" : cf.cfName));
		var r = b == null || com == null ? null : play(com, b);
		if (r == null) {
			if (s.log) Sys.println("hxmc: module cache: no walk kept for " + core.Globals.sTypePath(c.clPath) + "." + (cf == null ? "__init__" : cf.cfName));
			return e;
		}
		return r;
	}

	static function findType(com:CommonContext, i:BytesInput):Null<ModuleType> {
		var mp = ModuleStore.rpath(i);
		var name = ModuleStore.rstr(i);
		var m = com.moduleLut.findOpt(mp);
		if (m == null) return null;
		for (t in m.mTypes)
			if (core.TFunctions.tInfos(t).mtPath.name == name) return t;
		return null;
	}

	static function play(com:CommonContext, b:Bytes):Null<TExpr> {
		var i = new BytesInput(b);
		var nodes:Array<TExpr> = [];
		var p = core.Globals.nullPos;
		var t = core.TFunctions.tDynamic;
		inline function mk(d:TExprDef):TExpr
			return core.TFunctions.mk(d, t, p);
		while (i.position < b.length)
			switch i.readByte() {
				case 0:
					i.readByte();
					var mt = findType(com, i);
					if (mt == null) return null;
					nodes.push(mk(TTypeExpr(mt)));
				case 1:
					switch findType(com, i) {
						case TClassDecl(c): nodes.push(mk(TNew(c, [], [])));
						case _: return null;
					}
				case _:
					var mt = findType(com, i);
					var f = ModuleStore.rstr(i);
					switch mt {
						case TClassDecl(c) if (c.clStatics.exists(f)):
							nodes.push(mk(TField(mk(TConst(TNull)), FStatic(c, c.clStatics.get(f)))));
						case _:
							return null;
					}
			}
		return mk(TBlock(nodes));
	}

	public static function encode(s:ModuleCacheState, sign:String, p:GlobalTypePath):Bytes {
		var map = s.skeletons.get(moduleKey(sign, p));
		var o = new BytesOutput();
		var keys = map == null ? [] : [for (k in map.keys()) k];
		keys.sort(Reflect.compare);
		o.writeInt32(keys.length);
		for (k in keys) {
			ModuleStore.str(o, k);
			var b = map.get(k);
			o.writeInt32(b.length);
			o.write(b);
		}
		return o.getBytes();
	}

	static function decode(b:Bytes):Map<String, Bytes> {
		var i = new BytesInput(b);
		var m = new Map<String, Bytes>();
		for (_ in 0...i.readInt32()) {
			var k = ModuleStore.rstr(i);
			m.set(k, i.read(i.readInt32()));
		}
		return m;
	}
}

