// hxmc: haxe/upstream/std/sys/FileSystem.hx over hxmc.NativeSys

package sys;

import hxmc.NativeSys;

/**
	This class provides information about files and directories.

	If `null` is passed as a file path to any function in this class, the
	result is unspecified, and may differ from target to target.

	See `sys.io.File` for the complementary file API.
**/
class FileSystem {
	/**
		Returns `true` if the file or directory specified by `path` exists.
	**/
	public static function exists(path:String):Bool
		return NativeSys.exists(path);

	/**
		Renames/moves the file or directory specified by `path` to `newPath`.

		If `path` is not a valid file system entry, or if it is not accessible,
		or if `newPath` is not accessible, an exception is thrown.
	**/
	public static function rename(path:String, newPath:String):Void
		if (!NativeSys.rename(path, newPath)) throw "Could not rename " + path + " to " + newPath;

	/**
		Returns `FileStat` information for the file or directory specified by
		`path`.
	**/
	public static function stat(path:String):FileStat {
		var a = NativeSys.stat(path);
		if (a == null) throw "Could not stat " + path;
		// hxmc: the times to the millisecond and below where statTimes has them (as
		// hl's, jvm's and Eval's: upstream's TestFileSystem.testStatSubSecond)
		var t = NativeSys.statTimes(path);
		inline function time(i:Int):Date
			return Date.fromTime(t == null ? a[2 + i] * 1000 : t[2 * i] * 1000 + t[2 * i + 1] / 1e6);
		return {
			gid: Std.int(a[0]),
			uid: Std.int(a[1]),
			atime: time(0),
			mtime: time(1),
			ctime: time(2),
			dev: Std.int(a[5]),
			ino: Std.int(a[6]),
			nlink: Std.int(a[7]),
			rdev: Std.int(a[8]),
			size: Std.int(a[9]),
			mode: Std.int(a[10])
		};
	}

	/**
		Returns the full path of the file or directory specified by `relPath`,
		which is relative to the current working directory. Symlinks will be
		followed and the path will be normalized.
	**/
	public static function fullPath(relPath:String):String {
		var p = NativeSys.fullPath(relPath);
		if (p == null) throw "Could not resolve " + relPath;
		return p;
	}

	/**
		Returns the full path of the file or directory specified by `relPath`,
		which is relative to the current working directory. The path doesn't
		have to exist.
	**/
	public static function absolutePath(relPath:String):String {
		if (haxe.io.Path.isAbsolute(relPath)) return relPath;
		return haxe.io.Path.join([Sys.getCwd(), relPath]);
	}

	/**
		Returns `true` if the file or directory specified by `path` is a directory.

		If `path` is not a valid file system entry or if its destination is not
		accessible, an exception is thrown.
	**/
	public static function isDirectory(path:String):Bool
		return NativeSys.isDirectory(path);

	/**
		Creates a directory specified by `path`.

		This method is recursive: The parent directories don't have to exist.

		If the directory cannot be created, an exception is thrown.
	**/
	public static function createDirectory(path:String):Void {
		var path = haxe.io.Path.removeTrailingSlashes(path);
		if (path == "" || NativeSys.isDirectory(path)) return;
		var parent = haxe.io.Path.directory(path);
		if (parent != "" && parent != path) createDirectory(parent);
		if (!NativeSys.createDirectory(path) && !NativeSys.isDirectory(path)) throw "Could not create directory " + path;
	}

	/**
		Deletes the file specified by `path`.

		If `path` does not denote a valid file, or if that file cannot be
		deleted, an exception is thrown.
	**/
	public static function deleteFile(path:String):Void
		if (!NativeSys.deleteFile(path)) throw "Could not delete file " + path;

	/**
		Deletes the directory specified by `path`. Only empty directories can
		be deleted.

		If `path` does not denote a valid directory, or if that directory cannot
		be deleted, an exception is thrown.
	**/
	public static function deleteDirectory(path:String):Void
		if (!NativeSys.deleteDirectory(path)) throw "Could not delete directory " + path;

	/**
		Returns the names of all files and directories in the directory specified
		by `path`. `"."` and `".."` are not included in the output.

		If `path` does not denote a valid directory, an exception is thrown.
	**/
	public static function readDirectory(path:String):Array<String> {
		var r = NativeSys.readDirectory(path);
		if (r == null) throw "Could not read directory " + path;
		return r;
	}
}
