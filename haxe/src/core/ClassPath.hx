package core;

enum ClassPathScope {
	Std;
	StdTarget;
	Lib(name:Null<String>);
	User;
}

enum FileKind {
	FFile;
}

// port: the `(string * string array)` of get_uncached_dir_listing
@:structInit class DirectoryListing {
	public var directory:String;
	public var files:Array<String>;

	public inline function new(directory:String, files:Array<String>) {
		this.directory = directory;
		this.files = files;
	}

	public inline function clone():DirectoryListing return new DirectoryListing(directory, files);
}

// port: `class virtual class_path`; DirectoryClassPath implements it whole.
interface IClassPath {
	public var path(get, never):String;
	public var scope(get, never):ClassPathScope;
	public var fileKind(get, never):FileKind;
	public function clone():IClassPath;
	public function clearCache():Void;
	public function getDirectoryPath():Null<String>;
	public function getUncachedDirListing(file:String):Null<DirectoryListing>;
	public function dump():Void;
	public function isStdPath():Bool;
	public function scopeString():String;
}

class DirectoryClassPath implements IClassPath {
	final classPath:String;
	final classPathScope:ClassPathScope;
	// port: readdir_cache, a Lookup.hashtbl_lookup (only looked up)
	var directoryCache:Map<String, Null<Array<String>>> = new Map();

	public function new(path:String, scope:ClassPathScope) {
		classPath = path;
		classPathScope = scope;
	}

	public var path(get, never):String;

	function get_path():String return classPath;

	public var scope(get, never):ClassPathScope;

	function get_scope():ClassPathScope return classPathScope;

	public var fileKind(get, never):FileKind;

	function get_fileKind():FileKind return FFile;

	public function clone():IClassPath {
		return new DirectoryClassPath(classPath, classPathScope);
	}

	public function clearCache():Void {
		directoryCache = new Map();
	}

	public function getDirectoryPath():Null<String> {
		return classPath;
	}

	public function getUncachedDirListing(file:String):Null<DirectoryListing> {
		var fullPath = classPath + file;
		var directory = core.OcamlFilename.dirname(fullPath);
		if (directoryCache.exists(directory)) return null;
		var listing:Null<Array<String>>;
		try listing = sys.FileSystem.readDirectory(directory)
		catch (_:Dynamic) listing = null;
		directoryCache.set(directory, listing);
		return listing == null ? null : {directory: directory, files: listing};
	}

	public function dump():Void {
		Sys.println('    dir ${StringTools.rpad(scopeString(), " ", 9)}: $classPath');
	}

	public function isStdPath():Bool {
		return classPathScope == Std;
	}

	public function scopeString():String {
		return switch (classPathScope) {
			case Std: "Std";
			case StdTarget: "StdTarget";
			case Lib(null): "Lib";
			case Lib(name): "Lib " + name;
			case User: "User";
		};
	}
}
