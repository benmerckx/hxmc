package hxmc.interp;

import haxe.io.Bytes;
import sys.io.File;
import hxmc.Obj;

// Mir macros' compiled functions kept across builds (docs/hxmc.md, "Macros
// on the Mir interpreter"): each function a bundle compiles for the
// interpreter (its descriptor, MirBuild to InterpGen) is an object of its
// own in the module cache's store (ObjectStore: <cache>/modules/<tool>/o/,
// per build of the compiler, with its limits and trim), under the key of
// its Fingerprint (its lowered IR, what MirBuild reads of the rest of the
// program, the digests of the callees it may inline) with the compiler's
// target and options (Driver.toolKey). What the descriptor depends on
// besides (InterpGen.deps: which of its calls by symbol are of interpreted
// functions) is kept with it and checked before it is used; a function
// using a thread-local variable emulated with an index of the process's is
// not kept. A bundle loads the objects of its functions it finds, appended
// in its order (Obj.append), as it would have compiled them. Off with the
// module cache (HXMC_MODULE_CACHE=0, -D hxmc.no-module-cache) and without a
// cache directory; HXMC_MIR_CACHE=0 turns it off alone, HXMC_MIR_CACHE=1 on
// without the module cache.
//
// The file: the object (ElfWriter), the header (its key, the function's
// symbol, then its dependencies, a line each), the header's length, MAGIC
// (the object read in place: ElfReader reads within its own length).
class BundleCache {
	static inline var MAGIC = 0x314d4248;

	final store:ObjectStore;
	final arm:Bool;
	// the files of the store this generation used, for its list (ObjectStore.record)
	var names:Array<String> = [];
	var named = new Map<String, Bool>();
	public var hits = 0;
	public var misses = 0;

	function new(store:ObjectStore, arm:Bool) {
		this.store = store;
		this.arm = arm;
	}

	// the cache for this compilation (null: off)
	public static function open(com:context.Common.CommonContext, arm:Bool):Null<BundleCache> {
		var env = Sys.getEnv("HXMC_MIR_CACHE");
		if (env == "0" || env != "1" && (Sys.getEnv("HXMC_MODULE_CACHE") == "0" || CacheDir.define(com, "hxmc.no-module-cache") != null)) return null;
		// (the list of the objects used: per command line and directory, as an output's is per output)
		var store = ObjectStore.open(haxe.io.Path.join([Sys.getCwd(), ".hxmc-mir-macros-" + Fingerprint.hash(Sys.args().join("\x00"))]));
		return store == null ? null : new BundleCache(store, arm);
	}

	function path(key:String):String
		return store.objectPath(key, "mir");

	function use(p:String) {
		var n = haxe.io.Path.withoutDirectory(p);
		if (named.exists(n)) return;
		named.set(n, true);
		names.push(n);
	}

	// the object of the function kept under key, if it is that function's and
	// what it depends on holds (null: compile it)
	public function get(key:String, sym:String, set:InterpGen.InterpSet):Null<Obj> {
		var p = path(key);
		var b = try File.getBytes(p) catch (_:Dynamic) null;
		var o = b == null ? null : read(b, key, sym, set);
		if (o == null) misses++ else {
			hits++;
			use(p);
		}
		return o;
	}

	function read(b:Bytes, key:String, sym:String, set:InterpGen.InterpSet):Null<Obj> {
		var len = b.length;
		if (len < 8 || b.getInt32(len - 4) != MAGIC) return null;
		var n = b.getInt32(len - 8);
		if (n < 0 || 8 + n > len) return null;
		var lines = b.getString(len - 8 - n, n).split("\n");
		if (lines.length < 2 || lines[0] != key || lines[1] != sym) return null;
		for (k in 2...lines.length) {
			var d = lines[k];
			if (d == "") continue;
			var s = d.substr(1);
			switch d.charCodeAt(0) {
				case "+".code if (set.syms.exists(s)):
				case "-".code if (!set.syms.exists(s)):
				case _:
					return null;
			}
		}
		return try ElfReader.read(b) catch (_:Dynamic) null;
	}

	// a function compiled (its object alone, deps: InterpGen.deps), kept
	public function put(key:String, sym:String, obj:Obj, deps:Array<String>) {
		var seen = new Map<String, Bool>();
		var lines = [key, sym];
		for (d in deps) {
			if (StringTools.startsWith(d, "!")) return;
			if (seen.exists(d)) continue;
			seen.set(d, true);
			lines.push(d);
		}
		var head = Bytes.ofString(lines.join("\n"));
		var elf = ElfWriter.write(obj, arm);
		var b = Bytes.alloc(elf.length + head.length + 8);
		b.blit(0, elf, 0, elf.length);
		b.blit(elf.length, head, 0, head.length);
		b.setInt32(elf.length + head.length, head.length);
		b.setInt32(elf.length + head.length + 4, MAGIC);
		// (written beside and renamed into place, over one whose dependencies did not hold)
		var p = path(key);
		var tmp = p + "." + CacheDir.nonce() + ".tmp";
		try {
			File.saveBytes(tmp, b);
			if (CacheDir.replace(tmp, p)) CacheDir.wrote(b.length);
		} catch (_:Dynamic) {
			try sys.FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
		}
		use(p);
	}

	// the list of the objects this generation used (what the store's trim keeps)
	public function record()
		store.record(names);
}
