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
import core.ds.VectorTools.vector;
import hxmc.ModuleCache;
import hxmc.ModuleCache.Closure;
using core.ds.VectorTools;

class ModuleCacheState {
	public var dir:String;
	public var indexPath:String;
	public var com:CommonContext;
	public var index:StoreIndex;
	// per role (0: the program's context, 1: the macros'), its signature and
	// defines (the macros': predicted while that context does not exist)
	public var signs = new haxe.ds.Vector<Null<String>>(2);
	public var defs = new haxe.ds.Vector<Null<haxe.ds.StringMap<String>>>(2);
	// per role, the variant restored for each module (ModuleCache.key)
	public var chosen:haxe.ds.Vector<Map<String, Variant>> = vector(new Map<String, Variant>(), new Map<String, Variant>());
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
	var alternatives:haxe.ds.Vector<Map<String, Array<Variant>>> = vector(new Map<String, Array<Variant>>(), new Map<String, Array<Variant>>());

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
