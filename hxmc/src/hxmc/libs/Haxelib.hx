package hxmc.libs;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// `haxelib path <libraries>` without a process: what haxelib 4.2.0 (the
// client upstream ships, extra/haxelib_src at the pinned commit) answers,
// as the exit code, standard output and standard error of the process: the
// `haxelib` the compiler asks outside lix's scopes (Scope.haxelib, behind
// context.Common's haxelibHook: add_libs, the cpp generator), and lix's
// scopes for the libraries they leave to haxelib (Scope.Build). Its parts, in
// haxelib's order and with its messages:
// - the command line (client/Main.hx): --global, --cwd <dir>, `path` and the
//   libraries, name[:version];
// - the repository (api/RepoManager.hx, Repository.get): a .haxelib in the
//   working directory or a parent, else the global one: HAXELIB_PATH,
//   ~/.haxelib, /etc/.haxelib, on Windows its default; the warnings of a
//   repository of another format (Main.getRepository);
// - the versions (api/Repository.hx): name:version, else the .dev path
//   (%VAR% expanded, HAXELIB_DEV_FILTER), else .current; a name's
//   capitalization from .name;
// - the lines (api/GlobalScope.hx, getArgsAsHxmlWithDependencies): -L for
//   ndll/, extraParams.hxml, haxelib.json's class path, -D name=version, the
//   documentation's define and metadata files (the compiler is 5.x, past
//   haxelib's 4.3.0-rc.1 test), then the dependencies, sorted, depth first,
//   each library once.
// haxelib is a Neko program: its file system calls ignore a trailing slash,
// and haxe.Json's message for an unexpected end reads its char as null.
// What haxelib does besides is left out, none of it changing the answer:
// running a newer haxelib installed in the repository, writing the format
// version of an empty global repository, creating Windows' default
// repository and its configuration file (here: an empty repository).
class Haxelib {
	static final IS_WINDOWS = Sys.systemName() == "Windows";

	// args: haxelib's (add_libs: --cwd <dir> | --global, path, libraries);
	// cwd: the process's working directory; env: its environment
	public static function run(args:Array<String>, cwd:String, env:String->Null<String>):Output {
		var h = new Haxelib(cwd, env);
		var out = new StringBuf();
		var code = try {
			h.main(args, out);
			0;
		} catch (e:Failed) {
			h.err.add(e.message + "\n");
			1;
		}
		return {code: code, stdout: out.toString(), stderr: h.err.toString()};
	}

	final env:String->Null<String>;
	// (Cli.printWarning's)
	final err = new StringBuf();
	var cwd:String;
	// the repository
	var path:String;

	function new(cwd:String, env:String->Null<String>) {
		this.cwd = cwd;
		this.env = env;
	}

	function main(args:Array<String>, out:StringBuf) {
		var global = false, i = 0;
		while (i < args.length) switch args[i] {
			case "--global":
				global = true;
				i++;
			case "--cwd" if (i + 1 < args.length):
				// (Main.updateCwd: Sys.setCwd, then Sys.getCwd's path)
				var dir = args[i + 1];
				var full = try FileSystem.fullPath(Path.isAbsolute(dir) ? dir : Path.join([cwd, dir])) catch (_:Dynamic) null;
				if (full == null || !isDirectory(full)) fail('Directory $dir unavailable');
				cwd = Path.addTrailingSlash(full);
				i += 2;
			case _:
				break;
		}
		if (args[i] != "path") throw new Failed('hxmc: `haxelib ${args.join(" ")}` is only answered by haxelib itself');
		repository(global);
		// (Main.extractLibArgs)
		var libraries:Array<Lib> = [
			for (arg in args.slice(i + 1)) {
				var name = arg, version:Null<String> = null;
				if (LIBRARY_AND_VERSION.match(arg)) {
					name = LIBRARY_AND_VERSION.matched(1);
					var v = LIBRARY_AND_VERSION.matched(2);
					if (v != null) version = v.split(":")[0];
				}
				name = projectName(name);
				if (version != null && !isVersion(version)) fail('`$version` is not a valid library version');
				{library: name, version: version};
			}
		];
		if (libraries.length == 0) return;
		out.add(argsAsHxml(libraries) + "\n");
	}

	static final LIBRARY_AND_VERSION = ~/^(.+?)(?::(.*))?$/;

	// (Main.getRepository: Repository.get or getGlobal, the format's warnings)
	function repository(global:Bool) {
		var local = if (global) null else localPath(cwd);
		var version = if (local == null) {
			path = globalPath();
			// (an empty global repository is initialized at the current format)
			if (!exists(path) || FileSystem.readDirectory(path).length == 0) 1 else formatVersion();
		} else {
			path = local;
			formatVersion();
		}
		if (version < 1) warn('Repository requires reformatting. To reformat, run `haxelib fixrepo' + (global ? " --global" : "") + "`.");
		else if (version > 1) warn("Repository is incompatible with this version of haxelib. Please run `haxelib update haxelib`.");
	}

	function warn(message:String)
		err.add('Warning: $message\n');

	// (RepoReformatter.getRepositoryVersion)
	function formatVersion():Int {
		var v = try Std.parseInt(File.getContent(Path.join([path, ".repo-version"])).trim()) catch (_:Dynamic) 0;
		return v == null ? 0 : v;
	}

	// (RepoManager)
	static function localPath(dir:String):Null<String> {
		if (dir == "") return null;
		var repo = Path.join([dir, ".haxelib"]);
		if (exists(repo) && isDirectory(repo)) return Path.addTrailingSlash(FileSystem.fullPath(repo));
		return localPath(Path.directory(dir));
	}

	function globalPath():String {
		var rep = configuredGlobalPath();
		if (rep == null) {
			if (!IS_WINDOWS) throw new Failed("Error: This is the first time you are running haxelib. Please run `haxelib setup` first.");
			// (which haxelib creates and configures as the global repository)
			return windowsDefaultPath();
		}
		if (!exists(rep)) throw new Failed('Error: Haxelib repository $rep does not exist. Please run `haxelib setup` again.');
		if (!isDirectory(rep))
			throw new Failed('Error: Haxelib repository $rep exists, but is a file, not a directory. Please remove it and run `haxelib setup` again.');
		return rep;
	}

	function configuredGlobalPath():Null<String> {
		var v = env("HAXELIB_PATH");
		if (v != null) return Path.addTrailingSlash(v.trim());
		try return Path.addTrailingSlash(File.getContent(configFile()).trim()) catch (_:Dynamic) {}
		if (!IS_WINDOWS) try return Path.addTrailingSlash(File.getContent("/etc/.haxelib").trim()) catch (_:Dynamic) {}
		return null;
	}

	function configFile():String
		return Path.join([homePath(), ".haxelib"]);

	function homePath():String {
		var home = if (IS_WINDOWS) {
			var home = env("USERPROFILE");
			if (home == null) {
				var drive = env("HOMEDRIVE"), path = env("HOMEPATH");
				if (drive != null && path != null) home = drive + path;
			}
			if (home == null) fail("Could not determine home path. Please ensure that USERPROFILE or HOMEDRIVE+HOMEPATH environment variables are set.");
			home;
		} else {
			var home = env("HOME");
			if (home == null) fail("Could not determine home path. Please ensure that HOME environment variable is set.");
			home;
		}
		return home;
	}

	function windowsDefaultPath():String {
		var haxepath = env("HAXEPATH");
		if (haxepath != null) return Path.addTrailingSlash(Path.join([haxepath.trim(), "lib"]));
		return Path.addTrailingSlash(Path.join([Path.directory(configFile()), "haxelib"]));
	}

	// (Repository)
	function addToRepoPath(name:String, ?sub:String):String
		return Path.join([path, safe(name).toLowerCase(), sub != null ? sub : ""]);

	function rootPath(name:String):String
		return Path.addTrailingSlash(addToRepoPath(name));

	// (a semver's directory is itself, git's and hg's are git and hg)
	function versionPath(name:String, version:String):String
		return Path.addTrailingSlash(addToRepoPath(name, safe(version).toLowerCase()));

	function validVersionPath(name:String, version:String):String {
		if (!exists(rootPath(name))) fail('Library $name is not installed');
		var path = versionPath(name, version);
		if (!exists(path)) fail('Library $name version $version is not installed');
		return path;
	}

	function currentVersion(name:String):String {
		if (!exists(rootPath(name))) fail('Library $name is not installed');
		var file = addToRepoPath(name, ".current");
		if (!exists(file)) fail('No current version set for library \'$name\'');
		return try File.getContent(file).trim() catch (e:Dynamic) fail('Failed when reading the current version for library \'$name\': $e');
	}

	function devPath(name:String):Null<String> {
		if (!exists(rootPath(name))) fail('Library $name is not installed');
		var file = addToRepoPath(name, ".dev");
		if (!exists(file)) return null;
		var expanded = ~/%([A-Za-z0-9_]+)%/g.map(File.getContent(file).trim(), r -> {
			var v = env(r.matched(1));
			v == null ? "" : v;
		});
		var path = Path.addTrailingSlash(Path.normalize(expanded));
		var filter = env("HAXELIB_DEV_FILTER");
		if (filter != null && !Lambda.exists(filter.split(";"), f -> path.toLowerCase().startsWith(Path.normalize(f).toLowerCase())))
			return null;
		return path;
	}

	function correctName(name:String):String {
		if (!exists(rootPath(name))) fail('Library $name is not installed');
		var file = addToRepoPath(name, ".name");
		if (!exists(file)) return name.toLowerCase();
		var content = try File.getContent(file) catch (e:Dynamic) fail('Failed when checking the name for library \'$name\': $e');
		return projectName(content.trim());
	}

	// (GlobalScope)
	function resolveVersionAndPath(library:String, version:Null<String>):{path:String, version:String} {
		if (version != null) return {path: validVersionPath(library, version), version: version};
		var dev = devPath(library);
		if (dev != null) return {path: dev, version: "dev"};
		var current = currentVersion(library);
		return {path: validVersionPath(library, current), version: current};
	}

	function argsAsHxml(libraries:Array<Lib>):String {
		var lines = new StringBuf();
		function addLine(s:String)
			lines.add('$s\n');
		// (a GenericStack, its top at the end: the first library on top)
		var stack = libraries.copy();
		stack.reverse();
		var topLevel = stack.copy();
		var included = new Map<String, String>();
		while (stack.length > 0) {
			var cur = stack.pop();
			var library = correctName(cur.library);
			var version = cur.version;
			if (included.exists(library)) {
				var other = included[library];
				if (topLevel.contains(cur) && version != null && version != other)
					fail('Cannot process `${cur.library}:$version`: Library $library has two versions included : $other and $version');
				continue;
			}
			var resolved = resolveVersionAndPath(library, version);
			included[library] = resolved.version;
			var ndll = resolved.path + "ndll/";
			if (exists(ndll)) addLine('-L $ndll');
			try addLine(normalizeHxml(File.getContent(resolved.path + "extraParams.hxml"))) catch (_:Dynamic) {}
			var json = try File.getContent(resolved.path + "haxelib.json") catch (_:Dynamic) null;
			var info = readData(json, library);
			addLine(if (info.classPath != "") Path.addTrailingSlash(Path.join([resolved.path, info.classPath])) else resolved.path);
			addLine('-D ${info.name}=${info.version}');
			var doc:Dynamic = info.documentation;
			if (doc != null) {
				if (doc.defines != null && doc.defines != "")
					addLine('--macro registerDefinesDescriptionFile(\'${Path.join([resolved.path, doc.defines])}\', \'${info.name}\')');
				if (doc.metadata != null && doc.metadata != "")
					addLine('--macro registerMetadataDescriptionFile(\'${Path.join([resolved.path, doc.metadata])}\', \'${info.name}\')');
			}
			// (Dependencies.extractDataArray: sorted, each version read; then
			// pushed from the last, the first on top)
			var names = Reflect.fields(info.dependencies);
			names.sort(Reflect.compare);
			var deps:Array<Lib> = [
				for (name in names) {
					var v:String = Reflect.field(info.dependencies, name);
					{library: name, version: v == "" ? null : dependencyVersion(v)};
				}
			];
			while (deps.length > 0) {
				var d = deps.pop();
				stack.push({library: projectName(d.library), version: d.version});
			}
		}
		return lines.toString().trim();
	}

	// (Data.readData: CheckSyntax with a haxelib.json, NoCheck without)
	function readData(json:Null<String>, defaultName:String):{name:String, version:String, classPath:String, dependencies:Dynamic, documentation:Dynamic} {
		var doc:Dynamic = if (json == null) null else try haxe.Json.parse(json) catch (e:Dynamic)
			fail('JSON parse error: ' + Std.string(e).replace('Invalid char 0 at position ${json.length}', 'Invalid char null at position ${json.length}'));
		if (doc == null) doc = {name: defaultName, version: "0.0.0"};
		if (nameError(doc.name) != null) doc.name = defaultName;
		if (!isSemVer(doc.version)) doc.version = "0.0.0";
		// (cleanDependencies)
		var deps:Dynamic = doc.dependencies;
		if (deps != null)
			for (name in Reflect.fields(deps)) {
				projectName(name);
				if (!isUsable(Reflect.field(deps, name))) Reflect.setField(deps, name, "");
			}
		if (deps == null) doc.dependencies = {};
		if (doc.classPath == null) doc.classPath = "";
		return {
			name: doc.name,
			version: doc.version,
			classPath: Std.string(doc.classPath),
			dependencies: doc.dependencies,
			documentation: doc.documentation
		};
	}

	// (Neko's sys.FileSystem: the path without its trailing slashes, but a root)
	static function compatible(path:String):String
		return if (path.charCodeAt(1) == ":".code && path.length <= 3) Path.addTrailingSlash(path) else if (path == "/") path else Path.removeTrailingSlashes(path);

	static function exists(path:String):Bool
		return FileSystem.exists(compatible(path));

	static function isDirectory(path:String):Bool
		return FileSystem.isDirectory(compatible(path));

	// (Data.alphanum; ProjectName.ofString: the first rule that fails)
	static final ALPHANUM = ~/^[A-Za-z0-9_.-]+$/;

	static function nameError(s:Dynamic):Null<String> {
		var value = "`" + haxe.Json.stringify(s) + "`";
		if (!(s is String)) return '$value is not a String';
		var s:String = s;
		if (s.length < 3) return '$value is too short';
		if (!ALPHANUM.match(s)) return '$value contains invalid characters';
		if (["haxe", "all"].contains(s.toLowerCase())) return '$value is a reserved name';
		for (ext in [".zip", ".hxml"])
			if (s.toLowerCase().endsWith(ext)) return '$value ends with a reserved suffix';
		return null;
	}

	static function projectName(s:String):String {
		var e = nameError(s);
		if (e != null) fail(e);
		return s;
	}

	// (Data.safe)
	static function safe(name:String):String {
		if (!ALPHANUM.match(name)) fail("Invalid parameter : " + name);
		return name.split(".").join(",");
	}

	// (SemVer.isValid, with the client's preview tags)
	static final SEMVER = ~/^(\d|[1-9]\d*)\.(\d|[1-9]\d*)\.(\d|[1-9]\d*)(-([a-z]*)(\.(\d|[1-9]\d*))?)?$/;

	static function isSemVer(s:Dynamic):Bool
		return (s is String) && SEMVER.match((s : String).toLowerCase())
			&& (SEMVER.matched(5) == null || ["alpha", "beta", "preview", "rc"].contains(SEMVER.matched(5)));

	static function isVcs(s:String):Bool
		return s == "git" || s == "hg";

	// (Version.isValid)
	static function isVersion(s:String):Bool
		return isVcs(s) || isSemVer(s);

	// (DependencyVersion.isUsable)
	static function isUsable(s:Dynamic):Bool
		return (s is String) && isVcs((s : String).split(":")[0]) || s == "" || isSemVer(s);

	// (VersionDataHelper.extractVersion, as the version of a dependency: the
	// semver, or the vcs)
	static final VCS = ~/^(git|hg)(?::(.+?)(?:#(?:([a-f0-9]{7,40})|(.+)))?)?$/;

	static function dependencyVersion(s:String):String {
		if (isSemVer(s)) return s;
		if (!VCS.match(s)) fail('$s is not a valid library version');
		return VCS.matched(1);
	}

	// (Hxml.normalizeHxml)
	static function normalizeHxml(s:String):String
		return ~/\r?\n/g.split(s).map(StringTools.trim).filter(l -> l != "" && !l.startsWith("#")).join("\n");

	// a thrown String, as haxelib's main prints it
	static function fail(message:String):Dynamic
		throw new Failed('Error: $message');
}

typedef Output = {code:Int, stdout:String, stderr:String};

private typedef Lib = {library:String, version:Null<String>};

// (what haxelib prints on its standard error before it exits with 1)
private class Failed extends haxe.Exception {}
