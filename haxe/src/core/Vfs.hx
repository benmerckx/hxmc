/*
	File system view of the compilation server: file information and directory
	listings kept across compilations, invalidated by file system events, so
	that a compilation without changes does not query the file system again.

	Disabled by default: every function then goes to the file system. The
	server enables it with HAXE_VFS=watch.
*/

package core;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.thread.Mutex;
#if (target.name == "hxmc")
import hxmc.NativeUv as Uv;
#end

enum VfsKind {
	File;
	Dir;
	Missing;
}

@:structInit class VfsInfo {
	public final kind:VfsKind;
	public final mtime:Float;
	public final size:Int;
}

enum VfsMode {
	Off;
	Watched;
}

// port: an overlay: (name, content, mtime); the content as the file's bytes
@:structInit class VfsOverlay {
	public final name:String;
	public final content:Bytes;
	public final mtime:Float;
}

class Vfs {
	public static var mode:VfsMode = Off;

	static final mutex = new Mutex();

	// port: `Mutex.protect` (protectGet: of a function giving a value)
	static function protect(f:() -> Void):Void {
		mutex.acquire();
		try f() catch (e:haxe.Exception) {
			mutex.release();
			throw e;
		}
		mutex.release();
	}

	static function protectGet<R>(f:() -> R):R {
		mutex.acquire();
		var r = try f() catch (e:haxe.Exception) {
			mutex.release();
			throw e;
		}
		mutex.release();
		return r;
	}

	/* Entries are keyed by absolute paths, lowercase with forward slashes on
		Windows, so that the names given by file system events find them. */
	// port: the tables are Haxe maps: nothing is output in their order
	static final infos:Map<String, VfsInfo> = new Map();
	static final listings:Map<String, Null<Array<String>>> = new Map();
	/* The keys of the entries of each directory, to invalidate a directory
		without going through all the entries. */
	static final children:Map<String, Map<String, Bool>> = new Map();
	/* The keys of the symbolic links to each file: their entries change with the
		file, which the watch of their own directory does not see. */
	static final links:Map<String, Array<String>> = new Map();

	/* Contents of unsaved editor buffers, which take precedence over the files.
		Their modification time is negative and decreases on every change. */
	static final overlays:Map<String, VfsOverlay> = new Map();
	static var overlayCount = 0;
	static var overlayClock = 0.;

	public static final syscalls = new haxe.atomic.AtomicInt(0);
	public static final lastCompilationSyscalls = new haxe.atomic.AtomicInt(0);

	static final traceSyscalls = Sys.getEnv("HAXE_VFS_TRACE") != null;

	static function countSyscall(what:String, path:String):Void {
		if (traceSyscalls) Sys.stderr().writeString("vfs: " + what + " " + path + "\n");
		syscalls.add(1);
	}

	static function fullPath(path:String):String {
		var path = Path.getFullPath(path);
		var len = path.length;
		return if (len > 1 && (path.charAt(len - 1) == "/" || path.charAt(len - 1) == "\\") && !(len == 3 && path.charAt(1) == ":")) path.substr(0, len - 1) else path;
	}

	static function keyOfFull(path:String):String {
		return if (Globals.isWindows) Path.lowercaseAscii(path.split("\\").join("/")) else path;
	}

	/* The roots are "/" and "c:/". */
	static function parentKey(key:String):Null<String> {
		var len = key.length;
		var i = key.lastIndexOf("/");
		return if (i < 0) null else if (i == len - 1) null else if (i == 0) "/" else if (i == 2 && key.charAt(1) == ":") key.substr(0, 3) else key.substr(0, i);
	}

	static function childKey(key:String, name:String):String {
		return if (key.charAt(key.length - 1) == "/") key + name else key + "/" + name;
	}

	static function baseKey(key:String):String {
		var i = key.lastIndexOf("/");
		return if (i >= 0) key.substr(i + 1) else key;
	}

	static function addChildToUnlocked(parent:String, key:String):Void {
		var set = children.get(parent);
		if (set == null) {
			set = new Map();
			children.set(parent, set);
		}
		set.set(key, true);
	}

	static function addChildUnlocked(key:String):Void {
		var parent = parentKey(key);
		if (parent != null) addChildToUnlocked(parent, key);
	}

	static function invalidateContentsUnlocked(key:String):Void {
		var set = children.get(key);
		if (set != null) {
			children.remove(key);
			for (child in set.keys()) {
				infos.remove(child);
				listings.remove(child);
				invalidateContentsUnlocked(child);
			}
		}
	}

	/* Drops [key], everything below it, and the information and listing of its
		parent directory. */
	static function invalidateUnlocked(key:String):Void {
		invalidateContentsUnlocked(key);
		infos.remove(key);
		listings.remove(key);
		var parent = parentKey(key);
		if (parent != null) {
			infos.remove(parent);
			listings.remove(parent);
		}
	}

	static function takeLinksUnlocked(key:String):Array<String> {
		var l = links.get(key);
		if (l == null) return [];
		links.remove(key);
		return l;
	}

	public static function invalidate(path:String):Void {
		if (mode == Watched) {
			var key = keyOfFull(fullPath(path));
			protect(() -> invalidateUnlocked(key));
		}
	}

	// port: `let () = Path.on_directory_created := invalidate`
	static function __init__():Void {
		Path.onDirectoryCreated = invalidate;
	}

	/* The working directory seen by macros (Sys.setCwd, Sys.getCwd, their file
		accesses and processes): the compiler keeps the one of the compilation. */
	// port: an `Atomic.t`: a reference is read and written whole
	public static var macroCwd(default, null):Null<String> = null;

	// port: Unix.getcwd has no trailing slash, unlike Sys.getCwd
	static function unixGetcwd():String {
		var cwd = Sys.getCwd();
		return cwd.length > 1 && (cwd.charAt(cwd.length - 1) == "/" || cwd.charAt(cwd.length - 1) == "\\") && !(cwd.length == 3 && cwd.charAt(1) == ":") ? cwd.substr(0, cwd.length - 1) : cwd;
	}

	public static function getcwd():String {
		var dir = macroCwd;
		return if (dir != null) dir else unixGetcwd();
	}

	/* [path] for the file accesses of macros. */
	public static function resolve(path:String):String {
		var dir = macroCwd;
		return if (dir != null && OcamlFilename.isRelative(path)) OcamlFilename.concat(dir, path) else path;
	}

	// port: raises the failure of Unix.chdir's ENOENT (Unix.Unix_error (ENOENT, "chdir", dir))
	public static function setcwd(dir:String):Void {
		var dir = resolve(dir);
		if (!(FileSystem.exists(dir) && FileSystem.isDirectory(dir))) throw new VfsChdirError(dir);
		macroCwd = fullPath(dir);
	}

	public static function resetCwd():Void {
		macroCwd = null;
	}

	/* Whether changes are seen from file system events: false without the
		watched view, and where directories can only be checked again on each
		compilation. */
	public static function watching():Bool {
		return mode == Watched && Watcher.loop() != null;
	}

	public static function beginCompilation():Void {
		syscalls.store(0);
		if (mode == Watched) {
			Watcher.update();
			Watcher.revalidateUnwatchable();
		}
	}

	public static function endCompilation():Void {
		lastCompilationSyscalls.store(syscalls.load());
	}

	static final missing:VfsInfo = {kind: Missing, mtime: 0., size: 0};

	// port: Unix.stat: follows links; the modification time as OCaml's (st_mtim's
	// seconds and nanoseconds; Windows: Common.fileTime's)
	static function statUncached(path:String):VfsInfo {
		countSyscall("stat", path);
		return statInfo(path);
	}

	static function statInfo(path:String):VfsInfo {
		#if (target.name == "hxmc")
		if (!Globals.isWindows) {
			var t = hxmc.NativeSys.statTimes(path);
			if (t == null) return missing;
			return {kind: FileSystem.isDirectory(path) ? Dir : File, mtime: t[2] + t[3] / 1e9, size: Std.int(t[6])};
		}
		#end
		return try {
			var st = FileSystem.stat(path);
			{kind: FileSystem.isDirectory(path) ? Dir : File, mtime: st.mtime.getTime() / 1000.0, size: st.size};
		} catch (_:Dynamic) missing;
	}

	/* The paths a symbolic link goes through, up to the real path of the file:
		a change of any of them changes what the link gives. */
	static function linkTargets(path:String):Array<String> {
		var hops:Array<String> = [];
		var path = path;
		var n = 40;
		while (n > 0) {
			var target = VfsHost.readlink(path);
			if (target == null) break;
			var target = if (OcamlFilename.isRelative(target)) OcamlFilename.concat(OcamlFilename.dirname(path), target) else target;
			var target = fullPath(target);
			hops.unshift(target);
			path = target;
			n--;
		}
		var real = VfsHost.realpath(path);
		if (real != null) {
			var real = fullPath(real);
			if (!hops.contains(real)) hops.unshift(real);
		}
		hops.reverse();
		return hops;
	}

	/* Also gives the paths a symbolic link to a file goes through. */
	static function statLinkUncached(path:String):{info:VfsInfo, targets:Array<String>} {
		countSyscall("stat", path);
		if (!VfsHost.isLink(path)) return {info: statInfo(path), targets: []};
		var info = statInfo(path);
		return {info: info, targets: if (info.kind == File) linkTargets(path) else []};
	}

	static function findOverlay(key:String):Null<VfsOverlay> {
		return if (overlayCount == 0) null else protectGet(() -> overlays.get(key));
	}

	static function statFull(path:String, key:String):VfsInfo {
		var overlay = findOverlay(key);
		if (overlay != null) return {kind: File, mtime: overlay.mtime, size: overlay.content.length};
		if (mode == Off) return statUncached(path);
		var info = protectGet(() -> infos.get(key));
		if (info != null) return info;
		var r = statLinkUncached(path);
		/* The watch of the parent directory covers the changes of this entry. */
		var parent = switch parentKey(key) {
			case null: null;
			case parentKey:
				var parent = OcamlFilename.dirname(path);
				if (statFull(parent, parentKey).kind == Dir) {key: parentKey, path: parent} else null;
		}
		/* For a link, the watches of the directories of the paths it goes
			through. */
		var targets = [];
		for (target in r.targets) {
			var targetKey = keyOfFull(target);
			switch parentKey(targetKey) {
				case null:
				case _ if (targetKey == key):
				case targetParentKey:
					var targetParent = OcamlFilename.dirname(target);
					if (statFull(targetParent, targetParentKey).kind == Dir) targets.push({key: targetKey, parentKey: targetParentKey, parent: targetParent});
			}
		}
		protect(() -> {
			if (parent != null) Watcher.requestUnlocked(parent.key, parent.path);
			for (t in targets) {
				Watcher.requestUnlocked(t.parentKey, t.parent);
				var l = links.get(t.key);
				if (l == null) l = [];
				if (!l.contains(key)) links.set(t.key, [key].concat(l));
				addChildToUnlocked(t.parentKey, key);
			}
			infos.set(key, r.info);
			addChildUnlocked(key);
		});
		return r.info;
	}

	public static function stat(path:String):VfsInfo {
		var path = fullPath(path);
		return statFull(path, keyOfFull(path));
	}

	public static function exists(path:String):Bool {
		return if (mode == Off && overlayCount == 0) FileSystem.exists(path) else stat(path).kind != Missing;
	}

	public static function isDirectory(path:String):Bool {
		return stat(path).kind == Dir;
	}

	public static function fileExists(path:String):Bool {
		return stat(path).kind == File;
	}

	/* Modification time of [path], or 0 if it does not exist. */
	public static function mtime(path:String):Float {
		return stat(path).mtime;
	}

	// port: Sys.readdir, null where Sys_error
	static function readdirUncached(path:String, key:String):Null<Array<String>> {
		countSyscall("readdir", path);
		var entries = try FileSystem.readDirectory(path) catch (_:Dynamic) return null;
		var extra = if (overlayCount == 0) [] else protectGet(() -> {
			var acc = [];
			for (file => o in overlays) {
				switch parentKey(file) {
					case parent if (parent == key):
						var lname = keyOfFull(o.name);
						if (!Lambda.exists(entries, e -> keyOfFull(e) == lname)) acc.unshift(o.name);
					case _:
				}
			}
			acc;
		});
		return if (extra.length == 0) entries else entries.concat(extra);
	}

	/* Listing of directory [path], or None if it is not a directory. */
	public static function readdir(path:String):Null<Array<String>> {
		var path = fullPath(path);
		var key = keyOfFull(path);
		if (mode == Off) return readdirUncached(path, key);
		var cached = protectGet(() -> listings.exists(key) ? {l: listings.get(key)} : null);
		if (cached != null) return cached.l;
		var listing = readdirUncached(path, key);
		protect(() -> {
			if (listing != null) Watcher.requestUnlocked(key, path);
			listings.set(key, listing);
			addChildUnlocked(key);
		});
		return listing;
	}

	public static function setOverlay(path:String, content:Bytes):Void {
		var path = fullPath(path);
		var key = keyOfFull(path);
		protect(() -> {
			overlayClock = overlayClock - 1.;
			if (!overlays.exists(key)) overlayCount++;
			overlays.set(key, {name: OcamlFilename.basename(path), content: content, mtime: overlayClock});
			invalidateUnlocked(key);
		});
	}

	public static function removeOverlay(path:String):Void {
		var key = keyOfFull(fullPath(path));
		protect(() -> {
			if (overlays.exists(key)) overlayCount--;
			overlays.remove(key);
			invalidateUnlocked(key);
		});
	}

	/* Content of [path]: its overlay if it has one, the file otherwise. */
	public static function readFile(path:String):Bytes {
		var overlay = findOverlay(keyOfFull(fullPath(path)));
		if (overlay != null) return overlay.content;
		countSyscall("read", path);
		return sys.io.File.getBytes(path);
	}
}

/* libuv is not thread-safe: watches are started and events processed at the
	beginning of a compilation only, the directories to watch are queued
	meanwhile. */
@:allow(core.Vfs)
class Watcher {
	/* FSEvents delivers events with a latency: the directories are checked
		again on every compilation on macOS, as unwatchable ones. */
	static final isMacos = !Globals.isWindows && FileSystem.exists("/System/Library/CoreServices/SystemVersion.plist");

	// port: `Luv.Loop.init` on hxmc's libuv (hxmc.NativeUv); hosts without libuv
	// have no loop, every directory is then unwatchable (as on macOS)
	static var loopForced = false;
	static var loopId:Null<Int> = null;

	static function loop():Null<Int> {
		if (!loopForced) {
			loopForced = true;
			#if (target.name == "hxmc")
			if (!isMacos && Uv.available()) {
				var l = Uv.loopInit();
				if (l >= 0) loopId = l;
			}
			#end
		}
		return loopId;
	}

	static final watched:Map<String, Int> = new Map();
	static final unwatchable:Map<String, Bool> = new Map();
	static final pending:Map<String, String> = new Map();
	// port: the keys of the watches' handles, for the events' dispatch
	static final keysOfHandles:Map<Int, String> = new Map();

	static function requestUnlocked(key:String, path:String):Void {
		if (!watched.exists(key) && !unwatchable.exists(key)) pending.set(key, path);
	}

	/* A watch stays on the directory it was started on, even once deleted or
		moved: the watches of [key] and below are stopped, so that a directory
		created again at the same place gets a new one. */
	static function dropUnlocked(key:String):Void {
		var prefix = @:privateAccess Vfs.childKey(key, "");
		var dropped = [];
		for (k => handle in watched) if (k == key || StringTools.startsWith(k, prefix)) dropped.push({k: k, handle: handle});
		for (d in dropped) {
			watched.remove(d.k);
			#if (target.name == "hxmc")
			Uv.fsEventStop(d.handle);
			Uv.handleClose(d.handle);
			#end
		}
	}

	static inline final HK_FS_EVENT = 11;
	static inline final EV_FS_EVENT = 8;

	// port: `on_event key result`: [name] null for `None`, [status] < 0 for `Error`
	static function onEvent(key:String, status:Int, name:Null<String>, rename:Bool):Void {
		@:privateAccess Vfs.protect(() -> {
			if (status < 0) {
				dropUnlocked(key);
				@:privateAccess Vfs.invalidateUnlocked(key);
			} else if (name == null) {
				@:privateAccess Vfs.invalidateUnlocked(key);
			} else if (!rename) {
				/* A modification: the listing of the directory is the same. */
				var child = @:privateAccess Vfs.childKey(key, @:privateAccess Vfs.keyOfFull(name));
				@:privateAccess Vfs.infos.remove(child);
				for (l in @:privateAccess Vfs.takeLinksUnlocked(child)) @:privateAccess Vfs.infos.remove(l);
			} else {
				var name = @:privateAccess Vfs.keyOfFull(name);
				var child = @:privateAccess Vfs.childKey(key, name);
				/* The deletion or move of the watched directory itself is
					reported with its own name. */
				if (name == @:privateAccess Vfs.baseKey(key)) {
					dropUnlocked(key);
					@:privateAccess Vfs.invalidateUnlocked(key);
				}
				dropUnlocked(child);
				@:privateAccess Vfs.invalidateUnlocked(child);
				for (l in @:privateAccess Vfs.takeLinksUnlocked(child)) @:privateAccess Vfs.invalidateUnlocked(l);
			}
		});
	}

	#if (target.name == "hxmc")
	static function dispatch(id:Int, event:Int, status:Int, b:Dynamic):Void {
		if (event != EV_FS_EVENT) return;
		var key = keysOfHandles.get(id);
		if (key == null) return;
		var a:Array<Dynamic> = b;
		var file:Null<Bytes> = a == null ? null : a[0];
		var events:Int = a == null ? 0 : a[1];
		onEvent(key, status, file == null ? null : file.toString(), events & Uv.constant(12, 0) != 0);
	}
	#end

	/* Starts the pending watches, then processes the events received since the
		previous compilation. The entries of a directory read before its watch
		started are dropped, as a change may have been missed in between. */
	static function update():Void {
		var dirs = @:privateAccess Vfs.protectGet(() -> {
			var dirs = [for (key => path in pending) {key: key, path: path}];
			pending.clear();
			dirs;
		});
		var loop = loop();
		if (loop == null) {
			@:privateAccess Vfs.protect(() -> for (d in dirs) unwatchable.set(d.key, true));
			return;
		}
		#if (target.name == "hxmc")
		for (d in dirs) {
			var handle = Uv.handleInit(HK_FS_EVENT, loop, 0, 0);
			var started = handle >= 0 && Uv.fsEventStart(handle, Bytes.ofString(d.path), 0) >= 0;
			if (started) {
				@:privateAccess Vfs.protect(() -> {
					watched.set(d.key, handle);
					keysOfHandles.set(handle, d.key);
					@:privateAccess Vfs.invalidateContentsUnlocked(d.key);
					@:privateAccess Vfs.listings.remove(d.key);
				});
			} else {
				// port: a handle initialized but not started is closed again
				if (handle >= 0) Uv.handleClose(handle);
				@:privateAccess Vfs.protect(() -> {
					unwatchable.set(d.key, true);
					@:privateAccess Vfs.invalidateUnlocked(d.key);
				});
			}
		}
		// port: `Loop.run ~mode:`NOWAIT`, twice
		Uv.loopRun(loop, 2, dispatch);
		Uv.loopRun(loop, 2, dispatch);
		#end
	}

	static function revalidateUnwatchable():Void {
		@:privateAccess Vfs.protect(() -> for (key in unwatchable.keys()) @:privateAccess Vfs.invalidateUnlocked(key));
	}
}

// port: Unix.Unix_error (ENOENT, "chdir", dir)
class VfsChdirError extends haxe.Exception {
	public final dir:String;

	public function new(dir:String) {
		// port: as catch_unix_error prints it
		super("No such file or directory(chdir, " + dir + ")");
		this.dir = dir;
	}
}

// port: the link calls of the Unix library (lstat, readlink, realpath), on hxmc's
// libuv; hosts without libuv see no links
class VfsHost {
	static inline final FS_LSTAT = 14;
	static inline final FS_READLINK = 31;

	public static function isLink(path:String):Bool {
		#if (target.name == "hxmc")
		if (Uv.available()) {
			var req = Uv.reqNew();
			var r = Uv.fs(FS_LSTAT, -1, req, Bytes.ofString(path), null, 0, 0, 0, 0, 0, null, null);
			var link = false;
			if (r >= 0) {
				var b = Bytes.alloc(160);
				Uv.fsStat(req, b);
				// port: st_mode, S_IFMT and S_IFLNK
				link = (b.getInt32(8) & 0xF000) == 0xA000;
			}
			Uv.fsCleanup(req);
			Uv.reqFree(req);
			return link;
		}
		#end
		return false;
	}

	public static function readlink(path:String):Null<String> {
		#if (target.name == "hxmc")
		if (Uv.available()) {
			var req = Uv.reqNew();
			var r = Uv.fs(FS_READLINK, -1, req, Bytes.ofString(path), null, 0, 0, 0, 0, 0, null, null);
			var target = if (r >= 0) {
				var s = Uv.fsPtrString(req);
				s == null ? null : s.toString();
			} else null;
			Uv.fsCleanup(req);
			Uv.reqFree(req);
			return target;
		}
		#end
		return null;
	}

	public static function realpath(path:String):Null<String> {
		#if (target.name == "hxmc")
		return hxmc.NativeSys.realPath(path);
		#else
		return try FileSystem.fullPath(path) catch (_:Dynamic) null;
		#end
	}
}
