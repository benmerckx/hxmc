package hxmc;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

// The module cache's store (docs/hxmc.md, "Module cache"): one directory per
// build of the tool, <cache>/modules/<LAYOUT>-<tool>/ (CacheDir: the cache
// directory, its trim and its cap), in one layout for every user:
//
// - i/<key>: the indexes, each named by its CacheKey: a class path's typed
//   modules (ModuleCache), the objects an output's last build used (Driver)
//   or a command line's Mir macros (interp.BundleCache), an output's
//   up-to-date record (UpToDate); beside each, <key>.used, its last use;
// - p/<name>.pk: packs, the typed modules' HXB, one per build that writes;
// - o/<key>-<name>.o: objects, a module's (Driver) or a Mir macro
//   function's (interp.BundleCache), shared by every output and project.
//
// An index starts with a header naming the packs and objects it keeps (what
// the trim keeps: a pack or object goes with the last index naming it), then
// its user's bytes. Every file is written beside and renamed into place, so
// a build reading what another writes or removes finds it whole or missing.
// Another layout lives in another directory, which this tool never reads
// (the trim removes it as another tool's); an index of another layout or
// kind reads as missing.
class CacheStore {
	// the layout (in the tool directory's name and every index's header)
	public static inline var LAYOUT = 2;
	static inline var MAGIC = "hxmc-store";

	// the tool directory, with a trailing slash
	public final dir:String;

	function new(dir:String)
		this.dir = dir;

	// the running tool's directory's name in <cache>/modules/
	public static function toolName():String
		return LAYOUT + "-" + CacheDir.toolStamp();

	// the store of this build of the tool, its last use refreshed and the
	// cache trimmed when due (null: no cache directory, one that cannot be
	// written, or WASI)
	public static function open():Null<CacheStore> {
		if (Sys.systemName() == "Wasi") return null;
		var root = CacheDir.root();
		if (root == null) return null;
		var modules = root + "modules/";
		var dir = modules + toolName() + "/";
		try {
			for (d in ["i", "p", "o"])
				if (!FileSystem.exists(dir + d)) FileSystem.createDirectory(dir + d);
		} catch (_:Dynamic) {
			return null;
		}
		if (!FileSystem.exists(dir + "o")) return null;
		var used = dir + "used";
		if (!FileSystem.exists(used) || CacheDir.now() - CacheDir.mtime(used) > CacheDir.USED_REFRESH)
			if (!CacheDir.touch(used)) return null;
		CacheDir.trim(modules, dir);
		return new CacheStore(dir);
	}

	// ---- indexes

	public function indexPath(key:CacheKey):String
		return dir + "i/" + key;

	// an index's packs and objects and its bytes (null: missing, damaged, or
	// of another layout or kind)
	public function readIndex(key:CacheKey):Null<{names:Array<String>, data:Bytes}> {
		var b = try File.getBytes(indexPath(key)) catch (_:Dynamic) return null;
		return parse(b, key.kind);
	}

	static function header(kind:CacheKind):String
		return MAGIC + " " + LAYOUT + " " + kind;

	// (the header: a line with the layout and the kind, the number of names,
	// a line per name; then the bytes)
	static function parse(b:Bytes, ?kind:CacheKind):Null<{names:Array<String>, data:Bytes}> {
		var pos = 0;
		function line():Null<String> {
			var start = pos;
			while (pos < b.length && b.get(pos) != "\n".code)
				pos++;
			if (pos >= b.length) return null;
			return b.getString(start, pos++ - start);
		}
		var h = line();
		if (h == null || !StringTools.startsWith(h, MAGIC + " " + LAYOUT + " ")) return null;
		if (kind != null && h != header(kind)) return null;
		var n = Std.parseInt(line());
		if (n == null || n < 0) return null;
		var names = [];
		for (_ in 0...n) {
			var l = line();
			if (l == null) return null;
			names.push(l);
		}
		return {names: names, data: b.sub(pos, b.length - pos)};
	}

	// an index written, naming its packs and objects (unchanged: its last use
	// refreshed instead); false when it could not be written
	public function writeIndex(key:CacheKey, names:Array<String>, data:Bytes):Bool {
		var p = indexPath(key);
		var o = new haxe.io.BytesOutput();
		o.writeString(header(key.kind) + "\n" + names.length + "\n");
		for (n in names)
			o.writeString(n + "\n");
		o.write(data);
		var b = o.getBytes();
		var old = try File.getBytes(p) catch (_:Dynamic) null;
		if (old != null && old.compare(b) == 0) {
			CacheDir.used(p);
			return true;
		}
		var tmp = p + "." + CacheDir.nonce() + ".tmp";
		try {
			File.saveBytes(tmp, b);
			if (!CacheDir.replace(tmp, p)) return false;
			CacheDir.wrote(b.length - (old == null ? 0 : old.length));
			return true;
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
			return false;
		}
	}

	// an index's last use refreshed (at most every CacheDir.USED_REFRESH)
	public function used(key:CacheKey)
		CacheDir.used(indexPath(key));

	public function removeIndex(key:CacheKey)
		try FileSystem.deleteFile(indexPath(key)) catch (_:Dynamic) {};

	// the packs and objects an index file names, by their path in the tool
	// directory (CacheDir.trim)
	public static function namesOf(file:String):Array<String> {
		var b = try File.getBytes(file) catch (_:Dynamic) return [];
		var r = parse(b);
		return r == null ? [] : r.names;
	}

	// ---- packs

	// a pack's name in an index
	public static function packName(name:String):String
		return "p/" + name + ".pk";

	public function packPath(name:String):String
		return dir + packName(name);

	// (the packs open in this build)
	static final packs = new Map<String, sys.io.FileInput>();
	static final packsMutex = new sys.thread.Mutex();

	// size bytes of a pack at off (null: missing or short)
	public function readPack(name:String, off:Int, size:Int):Null<Bytes> {
		var path = packPath(name);
		packsMutex.acquire();
		try {
			var f = packs.get(path);
			if (f == null) packs.set(path, f = File.read(path, true));
			f.seek(off, SeekBegin);
			var b = Bytes.alloc(size);
			var n = 0;
			while (n < size) {
				var r = f.readBytes(b, n, size - n);
				if (r <= 0) throw "short";
				n += r;
			}
			packsMutex.release();
			return b;
		} catch (_:Dynamic) {
			packsMutex.release();
			return null;
		}
	}

	// the packs opened by this build, closed
	public static function closePacks() {
		packsMutex.acquire();
		for (f in packs)
			try f.close() catch (_:Dynamic) {}
		packs.clear();
		packsMutex.release();
	}

	// a pack written by write (which returns the bytes it wrote): false when
	// it could not be
	public function writePack(name:String, write:haxe.io.Output->Int):Bool {
		var p = packPath(name);
		var tmp = p + ".tmp";
		try {
			var o = File.write(tmp, true);
			var n = write(o);
			o.close();
			if (!CacheDir.replace(tmp, p)) return false;
			CacheDir.wrote(n);
			return true;
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
			return false;
		}
	}

	// ---- objects

	// an object's name in an index
	public static function objectName(key:CacheKey, name:String):String
		return "o/" + key + "-" + name + ".o";

	public function objectPath(key:CacheKey, name:String):String
		return dir + objectName(key, name);

	public function readObject(key:CacheKey, name:String):Null<Bytes>
		return try File.getBytes(objectPath(key, name)) catch (_:Dynamic) null;

	// an object written beside and renamed into place (one already there is
	// kept unless replace)
	public function writeObject(key:CacheKey, name:String, b:Bytes, replace = false) {
		var path = objectPath(key, name);
		if (!replace && FileSystem.exists(path)) return;
		var tmp = path + "." + CacheDir.nonce() + ".tmp";
		try {
			File.saveBytes(tmp, b);
			if (CacheDir.replace(tmp, path)) CacheDir.wrote(b.length);
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(tmp) catch (_:Dynamic) {}
		}
	}

	// a list of objects (their names, objectName) kept as an index of its own
	public function writeList(key:CacheKey, names:Array<String>)
		writeIndex(key, names, Bytes.alloc(0));
}
