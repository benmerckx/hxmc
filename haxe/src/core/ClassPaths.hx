package core;

import core.ClassPath.ClassPathScope;
import core.ClassPath.DirectoryClassPath;
import core.ClassPath.IClassPath;
import core.StringHelper;

@:structInit class ResolvedFile {
	public var file:String;
	public var classPath:IClassPath;

	public inline function new(file:String, classPath:IClassPath) {
		this.file = file;
		this.classPath = classPath;
	}

	public inline function clone():ResolvedFile return new ResolvedFile(file, classPath);
}

enum FileResolutionSpecificity {
	SpecificityNormal; /* Standard Module.hx file */
	SpecificityPlatformSpecific; /* Module.[platform].hx file matching current platform */
	SpecificityCustomExtension; /* Module.[custom].hx file matching --custom-extension config */
	SpecificityMacroSpecific; /* Module.macro.hx file while in macro context */
	SpecificityCoreApi; /* Module.hx takes priority when loading @:coreApi types */
}

// port: the `(resolved_file * file_resolution_specificity)` pair
@:structInit class FileLookup {
	public var resolvedFile:ResolvedFile;
	public var specificity:FileResolutionSpecificity;

	public inline function new(resolvedFile:ResolvedFile, specificity:FileResolutionSpecificity) {
		this.resolvedFile = resolvedFile;
		this.specificity = specificity;
	}

	public inline function clone():FileLookup return new FileLookup(resolvedFile, specificity);
}

class ClassPaths {
	/* We need to clean-up absolute ("") vs. cwd ("."). */
	public static final absoluteClassPath:IClassPath = new DirectoryClassPath("", User);

	var paths:Array<IClassPath> = [];
	// port: a Lookup.hashtbl_lookup; only looked up, never iterated
	var fileLookupCache:Map<String, Null<FileLookup>> = new Map();
	var customExtension:Null<String> = null;
	var platformExtension:String = "";
	var isLoadingCoreApi:Bool = false;

	public function new() {}

	public function lockContext(customExtension:Null<String>, platformName:String, coreApi:Bool):Void {
		this.customExtension = customExtension == null ? null : "." + customExtension;
		platformExtension = "." + platformName;
		isLoadingCoreApi = coreApi;
		clearCache();
	}

	public function asStringList():Array<String> {
		return paths.map(function(path) return path.path);
	}

	public function add(path:IClassPath):Void {
		paths.unshift(path);
		clearCache();
	}

	public function push(path:IClassPath):Void {
		paths.push(path);
		clearCache();
	}

	public function find(predicate:IClassPath->Bool):IClassPath {
		for (path in paths) if (predicate(path)) return path;
		throw core.ds.NotFound.raise();
	}

	function locate(file:String):Null<{dir:String, cp:IClassPath}> {
		var file = core.Path.comparablePath(file);
		var acc:Null<{dir:String, cp:IClassPath}> = null;
		for (cp in paths) {
			var dir = core.Path.addTrailingSlash(core.Path.comparablePath(cp.path));
			if (StringTools.startsWith(file, dir)) {
				if (acc == null || acc.dir.length < dir.length) acc = {dir: dir, cp: cp};
			}
		}
		return acc;
	}

	public function scopeOf(file:String):Null<ClassPathScope> {
		var located = locate(file);
		return located == null ? null : located.cp.scope;
	}

	public function packageOf(file:String):Null<Array<String>> {
		var located = locate(file);
		if (located == null) return null;
		var dir = located.dir;
		var full = core.Path.getFullPath(file);
		var rel = full.substr(dir.length, full.length - dir.length);
		var parts = rel.split("\\").join("/").split("/").filter(function(s) return s != "");
		if (parts.length == 0) return [];
		var last = parts.pop();
		parts.push(try core.OcamlFilename.chopExtension(last) catch (_:core.ds.InvalidArgument) last);
		return parts;
	}

	public function iter(callback:IClassPath->Void):Void {
		for (path in paths) callback(path);
	}

	public function exists(predicate:IClassPath->Bool):Bool {
		for (path in paths) if (predicate(path)) return true;
		return false;
	}

	public function filter(predicate:IClassPath->Bool):Array<IClassPath> {
		return paths.filter(predicate);
	}

	public function modify(f:IClassPath->Array<IClassPath>, cpl:Array<IClassPath>):Void {
		var acc:Array<IClassPath> = [];
		for (cp in cpl) acc = f(cp).concat(acc);
		acc.reverse();
		paths = acc;
		clearCache();
	}

	public function modifyInplace(transform:IClassPath->Array<IClassPath>):Void {
		modify(transform, paths);
	}

	public function getStdPaths():Array<IClassPath> {
		return filter(function(path) return path.isStdPath());
	}

	public function asList():Array<IClassPath> {
		return paths;
	}

	public function clearCache():Void {
		fileLookupCache = new Map();
		for (path in paths) path.clearCache();
	}

	public function findFileNoRaise(file:String):Null<FileLookup> {
		if (fileLookupCache.exists(file)) return fileLookupCache.get(file);
		var result:Null<FileLookup> = null;
		if (core.Path.isAbsolutePath(file)) {
			if (sys.FileSystem.exists(file)) result = {
				resolvedFile: {file: file, classPath: absoluteClassPath},
				specificity: SpecificityNormal
			};
		} else {
			for (path in paths) {
				var listing = path.getUncachedDirListing(file);
				if (listing == null) continue;
				result = cacheDirectory(path, listing.directory, file, listing.files);
				if (result != null) break;
			}
		}
		fileLookupCache.set(file, result);
		return result;
	}

	public function findFile(file:String):ResolvedFile {
		var result = findFileNoRaise(file);
		if (result == null) throw core.ds.NotFound.raise();
		return result.resolvedFile;
	}

	public function relativePath(file:String):String {
		function slashes(path:String) return path.split("\\").join("/");
		var fpath = slashes(core.Path.getFullPath(file));
		var fpathLower = lowercaseAscii(fpath);
		var flen = fpathLower.length;
		for (path in paths) {
			var path = path.path;
			var spath = lowercaseAscii(slashes(path));
			var slen = spath.length;
			if (slen > 0 && slen < flen && fpathLower.substr(0, slen) == spath) return fpath.substr(slen, flen - slen);
		}
		return file;
	}

	// port: String.lowercase_ascii
	static function lowercaseAscii(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			b.addChar(c >= "A".code && c <= "Z".code ? c + 32 : c);
		}
		return b.toString();
	}

	public function dump():Void {
		Sys.println('Class paths for $platformExtension${isLoadingCoreApi ? " (coreApi)" : ""}:');
		for (path in paths) path.dump();
	}

	function cacheDirectory(classPath:IClassPath, directory:String, search:String, listing:Array<String>):Null<FileLookup> {
		/*
			This function is invoked for each file in the `dir`.
			Each file is checked if it's specific for current platform
			(e.g. ends with `.js.hx` while compiling for JS) or current
			custom extension (e.g. ends with `.custom.hx` while compiling
			with `--custom-extension custom`)

			The lookup cache will store the full file path which is the more
			specific in current context (see `file_resolution_specificity` type)
		*/
		var found:Null<FileLookup> = null;
		var searchDirectory = core.OcamlFilename.dirname(search);
		for (ownName in listing) {
			var relative = searchDirectory == "." ? ownName : searchDirectory + "/" + ownName;
			/* `representation` is how the file is referenced to. E.g. when it's deduced from a module path. */
			var representation:String;
			var specificity:FileResolutionSpecificity;
			if (isLoadingCoreApi) {
				representation = relative;
				specificity = SpecificityCoreApi;
			} else {
				var suffix = StringHelper.extension(relative);
				var withoutExtension = StringHelper.removeExtension(relative);
				var secondExtension = StringHelper.extension(withoutExtension);
				/* The file contains double extension and the secondary one matches current custom extension */
				if (customExtension != null && secondExtension == customExtension) {
					representation = StringHelper.removeExtension(withoutExtension) + suffix;
					specificity = SpecificityCustomExtension;
				} else if (platformExtension == secondExtension && secondExtension == ".macro") {
					/* The file contains ".macro.hx" double extension and we are in macro context */
					representation = StringHelper.removeExtension(withoutExtension) + suffix;
					specificity = SpecificityMacroSpecific;
				} else if (platformExtension == secondExtension) {
					/* The file contains double extension and the secondary one matches current platform */
					representation = StringHelper.removeExtension(withoutExtension) + suffix;
					specificity = SpecificityPlatformSpecific;
				} else {
					representation = relative;
					specificity = SpecificityNormal;
				}
			}
			var fullPath = directory == "." ? ownName : directory + "/" + ownName;
			var resolved:FileLookup = {resolvedFile: {file: fullPath, classPath: classPath}, specificity: specificity};
			var previous = fileLookupCache.get(representation);
			if (!fileLookupCache.exists(representation)
				|| previous == null
				|| specificityRank(previous.specificity) < specificityRank(specificity)) fileLookupCache.set(representation, resolved);
			if (representation == search
				&& (found == null || specificityRank(found.specificity) < specificityRank(specificity))) found = resolved;
		}
		return found;
	}

	// port: OCaml compares constant constructors by declaration order
	static function specificityRank(specificity:FileResolutionSpecificity):Int {
		return switch (specificity) {
			case SpecificityNormal: 0;
			case SpecificityPlatformSpecific: 1;
			case SpecificityCustomExtension: 2;
			case SpecificityMacroSpecific: 3;
			case SpecificityCoreApi: 4;
		};
	}
}
