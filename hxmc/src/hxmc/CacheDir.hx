package hxmc;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

// The user's cache directory and its upkeep (the module cache's store,
// ModuleCache.hx): HXMC_CACHE, else $XDG_CACHE_HOME/hxmc or ~/.cache/hxmc,
// macOS ~/Library/Caches/hxmc, Windows %LOCALAPPDATA%\hxmc\cache. A
// directory of it (<cache>/modules/) holds one subdirectory per tool build
// (toolStamp); <tool>/used is the last build that used it, <tool>/<f>.used
// the last that used <f> (refreshed at most every USED_REFRESH). The trim
// removes the tool directories and the running tool's entries unused for
// MAX_UNUSED, the files of the running tool's directory nothing names, and,
// while the whole exceeds maxSize, the other tools' directories and then the
// running tool's entries, least recently used first, down to LOW_WATER of
// it. It runs at most every TRIM_INTERVAL (<dir>/trim.txt), and at once
// when the size the store keeps (<dir>/size.txt: the size the last trim
// found, then what each build wrote since) passes maxSize. Best effort:
// errors are ignored, a failed removal is retried next time; a build
// reading what another removes finds it missing and types or compiles it
// again. Files are written beside and renamed into place (replace), with a
// nonce in the temporary name.
class CacheDir {
	// seconds between two refreshes of a tool directory's last use
	public static inline var USED_REFRESH = 3600.0;
	// seconds between two trims of the cache
	static inline var TRIM_INTERVAL = 86400.0;
	// seconds without use after which a tool directory goes
	static inline var MAX_UNUSED = 14 * 86400.0;
	// seconds after which a file of a tool directory nothing names goes (a
	// build writes its packs and objects before the index and list naming them)
	static inline var ORPHAN_AGE = 3600.0;
	// what a trim beyond maxSize leaves, of it
	static inline var LOW_WATER = 0.8;

	// bytes the tool directories may take together: 1 GB, HXMC_CACHE_SIZE
	// overrides (bytes, or with K, M or G)
	static function maxSize():Float {
		var v = Sys.getEnv("HXMC_CACHE_SIZE");
		if (v == null || v == "") return 1024.0 * 1024 * 1024;
		var k = switch v.charAt(v.length - 1).toUpperCase() {
			case "K": 1024.0;
			case "M": 1024.0 * 1024;
			case "G": 1024.0 * 1024 * 1024;
			case _: 1.0;
		}
		var n = Std.parseFloat(k == 1 ? v : v.substr(0, v.length - 1));
		return Math.isNaN(n) || n < 0 ? 1024.0 * 1024 * 1024 : n * k;
	}

	// the user's cache directory, with a trailing slash (null: no place for it)
	public static function root():Null<String> {
		inline function env(n:String):Null<String> {
			var v = Sys.getEnv(n);
			return v == null || v == "" ? null : v;
		}
		var d = env("HXMC_CACHE");
		if (d == null) {
			var home = env("HOME");
			d = switch Sys.systemName() {
				case "Windows":
					var l = env("LOCALAPPDATA");
					if (l == null && env("USERPROFILE") != null) l = env("USERPROFILE") + "/AppData/Local";
					l == null ? null : l + "/hxmc/cache";
				case "Mac": home == null ? null : home + "/Library/Caches/hxmc";
				case _:
					var x = env("XDG_CACHE_HOME");
					x != null && Path.isAbsolute(x) ? x + "/hxmc" : home == null ? null : home + "/.cache/hxmc";
			}
		}
		return d == null ? null : Path.addTrailingSlash(d);
	}

	public static function now():Float
		return Date.now().getTime() / 1000;

	public static function mtime(p:String):Float
		return try FileSystem.stat(p).mtime.getTime() / 1000 catch (_:Dynamic) 0.0;

	static function stamp(p:String):String {
		var s = try FileSystem.stat(p) catch (_:Dynamic) null;
		return s == null ? "?" : s.size + "@" + s.mtime.getTime();
	}

	// this build of the tool (the binary, however it was named)
	public static function toolStamp():String {
		var p = try FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		return Fingerprint.hash("hxmc-tool|" + p + "|" + stamp(p)).substr(0, 16);
	}

	// a define's value (null: not defined), by its name with - or _
	public static function define(com:context.Common.CommonContext, name:String):Null<String> {
		var u = StringTools.replace(name, "-", "_");
		if (core.Define.rawDefined(com.defines, u)) return core.Define.rawDefinedValue(com.defines, u);
		if (core.Define.rawDefined(com.defines, name)) return core.Define.rawDefinedValue(com.defines, name);
		return null;
	}

	public static function touch(p:String):Bool {
		try {
			var d = Path.directory(p);
			if (!FileSystem.exists(d)) FileSystem.createDirectory(d);
			File.saveContent(p, Std.string(now()));
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	// tmp renamed to p, replacing it (where a rename does not replace a file,
	// as on Windows, p is deleted first)
	public static function replace(tmp:String, p:String):Bool {
		try {
			FileSystem.rename(tmp, p);
			return true;
		} catch (_:Dynamic) {}
		try {
			FileSystem.deleteFile(p);
			FileSystem.rename(tmp, p);
			return true;
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
			return false;
		}
	}

	// removes the tool directories of dir, and the entries of the running
	// tool's (mine: <name>, its last use in <name>.used), unused for
	// MAX_UNUSED, the files of mine's subdirectories no entry names written
	// before ORPHAN_AGE, then, while the whole exceeds maxSize, the other
	// tools' directories and mine's entries, least recently used first, down
	// to LOW_WATER of it (a pack or object with the last entry naming it);
	// at most once every TRIM_INTERVAL unless forced (two builds trimming at
	// once remove the same ones). The size it leaves goes to size.txt.
	public static function trim(dir:String, mine:String, force = false) {
		var t = now();
		var last = try Std.parseFloat(File.getContent(dir + "trim.txt")) catch (_:Dynamic) Math.NaN;
		if (!force && last <= t && t - last < TRIM_INTERVAL) return;
		var tmp = dir + "trim." + nonce() + ".tmp";
		if (!touch(tmp) || !replace(tmp, dir + "trim.txt")) return;
		var entries:Array<{files:Array<String>, dir:Null<String>, used:Float, size:Float, names:Array<String>}> = [];
		// (the files of mine's subdirectories, by their path in it, with the
		// number of entries naming each)
		var kids = new Map<String, {size:Float, mtime:Float, refs:Int}>();
		var nested = [];
		var total = 0.0;
		inline function size(f:String):Float
			return try FileSystem.stat(f).size catch (_:Dynamic) 0;
		for (n in try FileSystem.readDirectory(dir) catch (_:Dynamic) []) {
			var d = dir + n + "/";
			if (!FileSystem.isDirectory(d)) continue;
			var names = try FileSystem.readDirectory(d) catch (_:Dynamic) [];
			if (d == mine) {
				function walk(rel:String)
					for (g in try FileSystem.readDirectory(d + rel) catch (_:Dynamic) []) {
						if (FileSystem.isDirectory(d + rel + g)) {
							walk(rel + g + "/");
							nested.push(d + rel + g);
							continue;
						}
						var st = try FileSystem.stat(d + rel + g) catch (_:Dynamic) null;
						if (st == null) continue;
						kids.set(rel + g, {size: st.size, mtime: st.mtime.getTime() / 1000, refs: 0});
						total += st.size;
					}
				for (f in names) {
					// (the packs and objects: removed with the last entry naming them)
					if (FileSystem.isDirectory(d + f)) {
						walk(f + "/");
						continue;
					}
					var sz = size(d + f);
					total += sz;
					// (the leftovers of runs that did not finish)
					if (f.indexOf(".tmp") >= 0) {
						if (t - mtime(d + f) > TRIM_INTERVAL) try FileSystem.deleteFile(d + f) catch (_:Dynamic) {}
					} else if (f != "used" && !StringTools.endsWith(f, ".used")) {
						var u = d + f + ".used";
						var hasUsed = FileSystem.exists(u);
						entries.push({
							files: hasUsed ? [d + f, u] : [d + f],
							dir: null,
							used: Math.max(mtime(d + f), hasUsed ? mtime(u) : 0),
							size: sz + (hasUsed ? size(u) : 0),
							names: CacheDir.names(d + f)
						});
					}
				}
				continue;
			}
			var sz = 0.0;
			function walk(p:String)
				for (f in try FileSystem.readDirectory(p) catch (_:Dynamic) [])
					if (FileSystem.isDirectory(p + f)) walk(p + f + "/") else sz += size(p + f);
			walk(d);
			total += sz;
			entries.push({
				files: [],
				dir: d,
				// (one a trim renamed and did not finish removing: first)
				used: n.indexOf(".del.") >= 0 ? 0 : FileSystem.exists(d + "used") ? mtime(d + "used") : mtime(d),
				size: sz,
				names: []
			});
		}
		for (e in entries)
			for (k in e.names) {
				var c = kids.get(k);
				if (c != null) c.refs++;
			}
		// (what no entry names: a build's that did not finish, an earlier tool's)
		for (k => c in kids)
			if (c.refs == 0 && t - c.mtime > ORPHAN_AGE) {
				try FileSystem.deleteFile(mine + k) catch (_:Dynamic) {}
				total -= c.size;
			}
		for (p in nested)
			try FileSystem.deleteDirectory(p) catch (_:Dynamic) {}
		var max = maxSize();
		var target = total > max ? max * LOW_WATER : Math.POSITIVE_INFINITY;
		// (the other tools' directories first)
		entries.sort((a, b) -> a.dir != null && b.dir == null ? -1 : a.dir == null && b.dir != null ? 1 : a.used < b.used ? -1 : a.used > b.used ? 1 : 0);
		for (e in entries)
			if (t - e.used > MAX_UNUSED || total > target) {
				total -= e.size;
				if (e.dir != null) {
					// (renamed first: a build of that tool finds it whole or not at all)
					var gone = e.dir.substr(0, e.dir.length - 1) + ".del." + nonce() + "/";
					rmtree(try {
						FileSystem.rename(e.dir, gone);
						gone;
					} catch (_:Dynamic) e.dir);
					continue;
				}
				for (f in e.files)
					try FileSystem.deleteFile(f) catch (_:Dynamic) {}
				for (k in e.names) {
					var c = kids.get(k);
					if (c != null && --c.refs == 0) {
						try FileSystem.deleteFile(mine + k) catch (_:Dynamic) {}
						total -= c.size;
					}
				}
			}
		var stmp = dir + "size." + nonce() + ".tmp";
		try {
			File.saveContent(stmp, Std.string(Math.max(total, 0)) + "\n");
			replace(stmp, dir + "size.txt");
		} catch (_:Dynamic) {}
	}

	// the files of a tool directory an entry of it names (by their path in
	// it): an index's packs, an object list's objects
	static function names(file:String):Array<String> {
		var l = try {
			if (StringTools.endsWith(file, ".idx")) ModuleStore.packsOf(file) else if (StringTools.endsWith(file, ".objs")) ObjectStore.objectsOf(file) else [];
		} catch (_:Dynamic) [];
		var seen = new Map<String, Bool>();
		return [for (n in l) if (!seen.exists(n)) {
			seen.set(n, true);
			n;
		}];
	}

	// a tree removed (`used` last: a removal that fails keeps its date)
	static function rmtree(d:String) {
		for (f in try FileSystem.readDirectory(d) catch (_:Dynamic) [])
			if (FileSystem.isDirectory(d + f)) rmtree(d + f + "/") else if (f != "used") try FileSystem.deleteFile(d + f) catch (_:Dynamic) {}
		try FileSystem.deleteFile(d + "used") catch (_:Dynamic) {}
		try FileSystem.deleteDirectory(d) catch (_:Dynamic) {}
	}

	// (the bytes this build wrote into the store, not yet in size.txt)
	static var pending = 0.0;
	static final pendingMutex = new sys.thread.Mutex();

	// bytes written into the store (less those a file replaced)
	public static function wrote(n:Float) {
		pendingMutex.acquire();
		pending += n;
		pendingMutex.release();
	}

	// the end of a build that wrote into the store: what it wrote added to
	// size.txt (a line per build, appended; folded into one now and then),
	// and the store trimmed at once when that passes maxSize (or is unknown).
	// A build that wrote nothing reads nothing
	public static function settle() {
		pendingMutex.acquire();
		var n = pending;
		pending = 0;
		pendingMutex.release();
		if (n == 0) return;
		var root = root();
		if (root == null) return;
		var dir = root + "modules/";
		var lines = try File.getContent(dir + "size.txt").split("\n") catch (_:Dynamic) null;
		var size = n;
		if (lines != null)
			for (l in lines)
				if (l != "") size += Std.parseFloat(l);
		if (lines == null || !(size <= maxSize())) {
			trim(dir, dir + toolStamp() + "/", true);
			return;
		}
		if (lines.length > 256) {
			var tmp = dir + "size." + nonce() + ".tmp";
			try {
				File.saveContent(tmp, Std.string(size) + "\n");
				replace(tmp, dir + "size.txt");
			} catch (_:Dynamic) {}
			return;
		}
		try {
			var o = File.append(dir + "size.txt");
			o.writeString(Std.string(n) + "\n");
			o.close();
		} catch (_:Dynamic) {}
	}

	// the last use of a file of the cache (its <file>.used), refreshed at
	// most every USED_REFRESH
	public static function used(file:String) {
		var u = file + ".used";
		if (now() - Math.max(mtime(file), mtime(u)) > USED_REFRESH) touch(u);
	}

	// a 64-bit hash of bytes (two 32-bit lanes, four bytes a step), as 16
	// hex digits: the store's content hashes (files, blobs), much cheaper
	// than MD5 in the tool's code
	public static function hashBytes(b:haxe.io.Bytes):String {
		var h1 = 0x811c9dc5, h2 = 0x2545f491;
		var n = b.length, i = 0;
		while (i + 4 <= n) {
			var w = b.getInt32(i);
			h1 = (h1 ^ w) * 0x01000193;
			h1 ^= h1 >>> 15;
			h2 = (h2 ^ w) * 0x5bd1e995;
			h2 ^= h2 >>> 13;
			i += 4;
		}
		while (i < n) {
			var c = b.get(i++);
			h1 = (h1 ^ c) * 0x01000193;
			h2 = (h2 ^ c) * 0x5bd1e995;
		}
		h1 ^= n;
		h1 = (h1 ^ (h1 >>> 16)) * 0x85ebca6b;
		h2 = (h2 ^ (h2 >>> 13)) * 0xc2b2ae35;
		h1 ^= h1 >>> 16;
		h2 ^= h2 >>> 16;
		return StringTools.hex(h1 ^ (h2 >>> 7), 8) + StringTools.hex(h2 ^ (h1 >>> 11), 8);
	}

	// a name for temporary files (builds may write the same file at the same
	// time): the arguments, the time and Math.random, which is seeded per
	// process and thread (hxmc.rt.Random); no output depends on it
	public static function nonce():String
		return Fingerprint.hash(Sys.args().join("\x00") + "|" + Sys.time() + "|" + haxe.Timer.stamp() + "|" + Sys.programPath() + "|" + Math.random()).substr(0, 16);
}
