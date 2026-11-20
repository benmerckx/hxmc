package core;

import sys.FileSystem;
import sys.io.File;
import sys.io.FileOutput;
import sys.thread.Mutex;
import core.ds.Failure;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeSys;
#end

// port: FilePath.t
@:structInit class FilePathData {
	public var directory:Null<String>;
	public var fileName:Null<String>;
	public var extension:Null<String>;
	public var backslash:Bool;

	public inline function new(directory:Null<String>, fileName:Null<String>, extension:Null<String>, backslash:Bool) {
		this.directory = directory;
		this.fileName = fileName;
		this.extension = extension;
		this.backslash = backslash;
	}

	public inline function clone():FilePathData return new FilePathData(directory, fileName, extension, backslash);
}

class Path {
	// port: Unix.chdir back to a saved directory. Skips the call when the directory did
	// not change, so hosts without chdir support (JVM) can run the batch driver.
	public static function restoreCwd(cwd:String):Void {
		if (Sys.getCwd() != cwd) Sys.setCwd(cwd);
	}

	public static final isWindows = Sys.systemName() == "Windows";
	public static final pathSep = isWindows ? "\\" : "/";
	static final mkdirMutex = new Mutex();

	public static function getPathParts(file:String):Array<String> {
		/*
			this function is quite weird: it tries to determine whether the given
			argument is a .hx file path with slashes or a dotted module path and
			based on that it returns path "parts", which are basically a list of
			either folders or packages (which are folders too) appended by the module name

			TODO: i started doubting my sanity while writing this comment, let's somehow
			refactor this stuff so it doesn't mix up file and module paths and doesn't introduce
			the weird "path part" entity.
		*/
		var l = file.length;
		if (l > 3 && file.substr(l - 3, 3) == ".hx") {
			var f = file.substr(0, l - 3); /* strip the .hx */
			return f.split("\\").join("/").split("/"); /* TODO: wouldn't it be faster to Str.split here? */
		} else
			return file.split(".");
	}

	public static function checkInvalidChar(value:String):Void {
		for (index in 1...value.length) {
			var code = value.charCodeAt(index);
			if (!((code >= "A".code && code <= "Z".code)
				|| (code >= "a".code && code <= "z".code)
				|| (code >= "0".code && code <= "9".code)
				|| code == "_".code
				|| code == ".".code)) throw new Failure("Invalid character: " + StringHelper.sEscape(value.charAt(index)));
		}
	}

	public static function checkPackageName(value:String):Void {
		if (value.length == 0) throw new Failure("Package name must not be empty");
		else {
			var code = value.charCodeAt(0);
			if ((code < "a".code || code > "z".code) && code != "_".code) throw new Failure("Package name must start with a lowercase letter");
		}
		checkInvalidChar(value);
	}

	public static function parsePath(file:String):core.Globals.GlobalTypePath {
		var parts = getPathParts(file);
		function error(msg:String):Dynamic {
			var msg = "Could not process argument " + file + "\n" + msg;
			throw new Failure(msg);
		}
		function loop(index:Int, pack:Array<String>):core.Globals.GlobalTypePath {
			if (index == parts.length) return error("Package name must not be empty");
			var value = parts[index];
			if (index == parts.length - 1) {
				checkInvalidChar(value);
				return {pack: pack, name: value};
			}
			// port: `_ :: ("_std" :: l) -> loop l` drops "_std" and the part before it.
			if (parts[index + 1] == "_std") return loop(index + 2, pack);
			checkPackageName(value);
			pack.push(value);
			return loop(index + 1, pack);
		}
		try return loop(0, [])
		catch (e:Failure) return error(e.message);
	}

	public static function parseTypePath(value:String):{pack:Array<String>, name:String} {
		var path = parsePath(value);
		StringHelper.checkUppercase(path.name);
		return path;
	}

	// port: Str.full_split over "[/\\]+", walked in place.
	public static function normalizePath(path:String):String {
		var acc:Array<String> = [];
		var start = 0;
		var index = 0;
		while (index < path.length) {
			var code = path.charCodeAt(index);
			if (code == "/".code || code == "\\".code) {
				var value = path.substr(start, index - start);
				while (index < path.length && (path.charCodeAt(index) == "/".code || path.charCodeAt(index) == "\\".code)) index++;
				if (value == "." && acc.length == 0) {} else if (value == "..") {
					if (acc.length == 0) throw core.ds.Exit.raise();
					acc.pop();
				} else acc.push(value);
				start = index;
			} else index++;
		}
		if (start < path.length) acc.push(path.substr(start));
		return acc.join("/");
	}

	public static function isAbsolutePath(file:String):Bool {
		if (file.length == 0) return false;
		var first = file.charCodeAt(0);
		if (first == "/".code) return true;
		if ((first >= "A".code && first <= "Z".code)
			|| (first >= "a".code && first <= "z".code)) return isWindows && file.length > 1 && file.charCodeAt(1) == ":".code;
		return first == "\\".code && isWindows;
	}

	/**
		Returns absolute path.
		Resolves `.`, `..`, double slashes and trailing slashesw.
		Doesn't resolve symbolic links.
		Doesn't fix path case on Windows.
		Doesn't access file system (see https://github.com/HaxeFoundation/haxe/issues/9509#issuecomment-636360777)
	**/
	public static function getFullPath(file:String):String {
		if (isWindows) return try FileSystem.fullPath(file) catch (_:Dynamic) file;
		var length = file.length;
		inline function getcwd():String {
			// port: Unix.getcwd has no trailing slash, unlike Sys.getCwd.
			var cwd = Sys.getCwd();
			return cwd.length > 1 && StringTools.fastCodeAt(cwd, cwd.length - 1) == "/".code ? cwd.substr(0, cwd.length - 1) : cwd;
		}
		// port: the working directory only for a relative path, as upstream asks for it (a
		// getcwd opens the directory on macOS)
		var absolutePath = length > 0 && StringTools.fastCodeAt(file, 0) == "/".code ? file : length == 0 ? getcwd() : getcwd() + "/" + file;
		var needsNormalization = length > 0 && StringTools.fastCodeAt(file, length - 1) == "/".code;
		// port: has_dots_or_double_slash as a loop: only the first character of each segment is inspected.
		// (fastCodeAt: every index here is checked against the length, and
		// charCodeAt boxes its Null<Int> result on HashLink.)
		var index = 0;
		while (!needsNormalization && index < length) {
			var c = StringTools.fastCodeAt(file, index);
			if (c == ".".code) {
				if (index + 2 < length) /* path contains `../` or `./` */ needsNormalization = (StringTools.fastCodeAt(file, index + 1) == ".".code
					&& StringTools.fastCodeAt(file, index + 2) == "/".code)
					|| StringTools.fastCodeAt(file, index + 1) == "/".code;
				else if (index + 1 < length) /* path ends with `./` or `..` */ needsNormalization = StringTools.fastCodeAt(file, index + 1) == "/".code
					|| StringTools.fastCodeAt(file, index + 1) == ".".code;
				else needsNormalization = true; /* path ends with `.` */
			} else if (c == "/".code && index > 0) needsNormalization = true; /* double slash */
			if (!needsNormalization) {
				while (index < length && StringTools.fastCodeAt(file, index) != "/".code) index++;
				index++;
			}
		}
		if (!needsNormalization) return absolutePath;
		var parts = absolutePath.split("/");
		var skip = 0;
		var normalized:Array<String> = [];
		for (reverseIndex in 0...parts.length) {
			var current = parts[parts.length - reverseIndex - 1];
			if (current == "..") skip++;
			else if (current != "." && current != "") {
				if (skip > 0) skip--;
				else normalized.unshift(current);
			}
		}
		return "/" + normalized.join("/");
	}

	/** Returns absolute path (on Windows ensures proper case with drive letter upper-cased)
		Use for returning positions from IDE support functions */
	public static function getRealPath(path:String):String {
		// port: Extc.get_real_path fails for a missing file (falling back to `path`);
		// HashLink's fullPath returns null instead of throwing.
		#if (target.name == "hxmc")
		// port: Windows' get_real_path (each component as the file system spells it) is a native of the hxmc host
		if (isWindows) {
			var r = NativeSys.realPath(path);
			return r == null ? path : r;
		}
		#end
		var r = try FileSystem.fullPath(path) catch (_:Dynamic) null;
		return r == null ? path : r;
	}

	public static function addTrailingSlash(p:String):String {
		var l = p.length;
		return if (l == 0) "./" else switch p.charAt(l - 1) {
			case "\\" | "/": p;
			case _: p + "/";
		}
	}

	public static function comparablePath(f:String):String {
		var f = getFullPath(f == "" ? "." : f);
		return isWindows ? lowercaseAscii(f.split("\\").join("/")) : f;
	}

	public static function removeTrailingSlash(p:String):String {
		var l = p.length;
		return if (l == 0) "./" else switch p.charAt(l - 1) {
			case "\\" | "/": removeTrailingSlash(p.substr(0, l - 1));
			case _: p;
		}
	}

	public static function flatPath(path:{pack:Array<String>, name:String}):String {
		/* Replace _ with _$ in paths to prevent name collisions. */
		var escape = function(value:String) return value.split("_").join("_$");
		return path.pack.length == 0 ? escape(path.name) : path.pack.map(escape).join("_") + "_" + escape(path.name);
	}

	// port: the accumulators are arrays in list order; consing is `[x].concat(acc)`.
	public static function findDirectories(target:String, recursive:Bool, paths:Array<String>):Array<String> {
		var targetDirs = core.Globals.platforms.map(core.Globals.platformName);
		function loop(acc:Array<String>, dir:String):Array<String> {
			return try {
				var entries = try FileSystem.readDirectory(dir) catch (e:Dynamic) throw new SysError(dir + ": " + Std.string(e));
				var acc2 = acc;
				for (file in entries) {
					acc2 = switch file {
						case "." | "..":
							acc2;
						case _ if (isDirectory(dir + file) && file.charCodeAt(0) >= "a".code && file.charCodeAt(0) <= "z".code):
							if (targetDirs.indexOf(file) >= 0 && file != target) acc2 else {
								var full = (dir + file);
								if (recursive) loop([full].concat(acc2), full + "/") else [full].concat(acc2);
							}
						case _:
							acc2;
					}
				}
				acc2;
			} catch (_:SysError) acc;
		}
		var acc:Array<String> = [];
		for (dir in paths) acc = loop(acc, dir);
		return acc;
	}

	// port: Sys.is_directory raises Sys_error for a missing file (a broken symbolic link).
	static function isDirectory(path:String):Bool {
		if (!FileSystem.exists(path)) throw new SysError(path + ": No such file or directory");
		return FileSystem.isDirectory(path);
	}

	// port: Str works on bytes: a non-ASCII character becomes one `_` per UTF-8 byte.
	public static function makeValidFilename(s:String):String {
		var r = ~/[^A-Za-z0-9_\-\.,]/;
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charAt(i);
			if (r.match(c)) b.add(StringTools.lpad("", "_", haxe.io.Bytes.ofString(c).length)) else b.add(c);
		}
		return b.toString();
	}

	public static function moduleNameOfFile(file:String):String {
		// port: Str.split drops the empty fields at both ends
		var parts = new EReg("[/\\\\]+", "g").split(getRealPath(file)).filter(s -> s != "");
		return switch parts.length {
			case 0:
				core.Globals.die("", "path.ml");
			case n:
				var s = parts[n - 1];
				var l = s.split(".");
				l.reverse();
				var s = switch l {
					case [s]: s;
					/* file_ext; module_name */
					case [_, s]: s;
					/* file_ext; platform_ext; ...module_name */
					case _ if (l.length > 2):
						var sl = l.slice(2);
						sl.reverse();
						sl.join(".");
					case _: "";
				}
				s;
		}
	}

	// port: `acc` is in path order (upstream: reversed list); it is not mutated.
	public static function createFile(bin:Bool, ext:String, acc:Array<String>, parts:Array<String>):FileOutput {
		return switch parts {
			case []:
				core.Globals.die("", "path.ml");
			case [d]:
				var d = makeValidFilename(d);
				var maxlen = 200 - ext.length;
				var d = if (d.length > maxlen) d.substr(0, maxlen) else d;
				var ch = File.write(acc.concat([d]).join("/") + ext, bin);
				ch;
			case _:
				var d = parts[0];
				var dir = acc.concat([d]).join("/");
				mkdirMutex.acquire();
				try {
					if (!FileSystem.exists(removeTrailingSlash(dir))) FileSystem.createDirectory(dir);
				} catch (error:haxe.Exception) {
					mkdirMutex.release();
					throw error;
				}
				mkdirMutex.release();
				createFile(bin, ext, acc.concat([d]), parts.slice(1));
		}
	}

	public static function mkdirRecursive(base:String, parts:Array<String>):Void {
		for (directory in parts) {
			var path = base == "" ? directory : base == "/" ? "/" + directory : base + "/" + directory;
			var length = path.length;
			if (length > 0 && (path.charAt(length - 1) == "/" || path.charAt(length - 1) == "\\")) path = path.substr(0, length - 1);
			if (!(path == "" || (length == 2 && path.charAt(1) == ":")) && !FileSystem.exists(path)) FileSystem.createDirectory(path);
			base = path == "" ? "/" : path;
		}
	}

	/**
		Recursively creates `path`.
		Raises `Unix.Unix_error` exceptions as-is.
	**/
	public static function mkdirFromPathUnixErr(path:String):Void {
		// port: Str.split_delim "" is [] and EReg.split "" is [""]: both create nothing
		var parts = new EReg("[\\\\/]+", "g").split(path);
		switch parts {
			case []: /* path was "" */
			case _:
				var dirList = parts.slice(0, parts.length - 1);
				mkdirRecursive("", dirList);
		}
	}

	/**
		Recursively creates `path`.
		Converts all `Unix.Unix_error` exceptions to human-readable `Failure msg`.
	**/
	public static function mkdirFromPath(path:String):Void try mkdirFromPathUnixErr(path)
	catch (error:haxe.Exception) throw new Failure(error.message);

	public static function fullDotPath(pack:Array<String>, moduleName:String, typeName:String):{pack:Array<String>, name:String}
		return typeName == moduleName ? {pack: pack, name: moduleName} : {pack: pack.concat([moduleName]), name: typeName};

	public static function fileExtension(file:String):String {
		var parts = file.split(".");
		return parts.length == 0 ? "" : lowercaseAscii(parts[parts.length - 1]);
	}

	// port: ExtString.String.lowercase (ASCII only)
	public static function lowercaseAscii(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			b.addChar(c >= "A".code && c <= "Z".code ? c + 32 : c);
		}
		return b.toString();
	}

	public static function parseFilePath(path:String):FilePathData {
		if (path == "." || path == "..") return {
			directory: path,
			fileName: null,
			extension: null,
			backslash: false
		};
		var slash = path.lastIndexOf("/");
		var backslash = path.lastIndexOf("\\");
		var directory:Null<String> = null;
		var useBackslash = false;
		if (slash < backslash) {
			directory = path.substr(0, backslash);
			path = path.substr(backslash + 1);
			useBackslash = true;
		} else if (backslash < slash) {
			directory = path.substr(0, slash);
			path = path.substr(slash + 1);
		}
		if (path.length == 0) return {
			directory: directory,
			fileName: null,
			extension: null,
			backslash: useBackslash
		};
		var dot = path.lastIndexOf(".");
		return dot < 0 ? {
			directory: directory,
			fileName: path,
			extension: null,
			backslash: useBackslash
		} : {
			directory: directory,
			fileName: path.substr(0, dot),
			extension: path.substr(dot + 1),
			backslash: useBackslash
			};
	}

	public static function nameAndExtension(path:FilePathData):String {
		if (path.fileName == null) throw new Failure("File path has no name");
		return path.extension == null ? path.fileName : path.fileName + "." + path.extension;
	}
}

/**
	Stores a unique key for a file path.
**/
// port: the key type `UniqueKey.t` is String.
class UniqueKey {
	/**
		Returns absolute path guaranteed to be the same for different letter case.
		Use where equality comparison is required, lowercases the path on Windows
	**/
	public static function create(path:String):String return Path.isWindows ? Path.lowercaseAscii(Path.getFullPath(path)) : Path.getFullPath(path);

	public static function createLazy(path:String):LazyUniqueKey return {path: path, key: null};

	/**
		Calculates a key or retrieve a cached key.
	**/
	public static function lazyKey(value:LazyUniqueKey):String {
		if (value.key == null) value.key = create(value.path);
		return value.key;
	}

	/**
		Returns original path, which was used to create `lazy_t`
	**/
	public static function lazyPath(value:LazyUniqueKey):String return value.path;

	/**
		Check if the first key starts with the second key
	**/
	public static function startsWith(subject:String, start:String):Bool return StringTools.startsWith(subject, start);

	/**
		Get string representation of a key
	**/
	public static function toString(key:String):String return key;
}

/**
	Stores an original file path along with a lazily-calculated key.
**/
@:structInit class LazyUniqueKey {
	public var path:String;
	public var key:Null<String>;

	public inline function new(path:String, key:Null<String>) {
		this.path = path;
		this.key = key;
	}

	public inline function clone():LazyUniqueKey return new LazyUniqueKey(path, key);
}

// port: module FilePath; parse and name_and_extension are implemented in Path.
class FilePath {
	public static function create(directory:Null<String>, fileName:Null<String>, extension:Null<String>,
			backslash:Bool):FilePathData return {
			directory: directory,
			fileName: fileName,
			extension: extension,
			backslash: backslash
		};

	public static function parse(path:String):FilePathData return Path.parseFilePath(path);

	public static function nameAndExtension(path:FilePathData):String return Path.nameAndExtension(path);
}

// port: OCaml Sys_error
class SysError extends haxe.Exception {}
