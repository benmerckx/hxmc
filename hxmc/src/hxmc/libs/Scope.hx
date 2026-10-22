package hxmc.libs;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// lix's scopes, as its `haxe` shim (haxeshim, tools/lix/src/haxeshim)
// resolves -lib before the compiler sees it: the scope is the nearest
// .haxerc from the working directory up (or the one HAXESHIM_SCOPE names),
// else the global one, $HAXESHIM_ROOT/.haxerc (default ~/haxe), if that
// exists; without either there is none (Libraries resolves as without lix).
// Its "resolveLibs" (scoped by default, mixed for the global scope) decides:
// - scoped, mixed: haxe_libraries/<name>.hxml in the scope's directory is
//   read as lix's hxml (one argument per line, a flag and its value split
//   at the first space, ${VAR} interpolated: the environment, then
//   HAXE_LIBCACHE, SCOPE_DIR, CWD, __dirname), its -lib resolved in turn,
//   its hxml files expanded, all in the place of the -lib;
// - mixed, haxelib: haxelib's path (Haxelib, with HAXELIB_PATH the root's
//   haxelib, as the shim runs it) for the others, after the build's
//   arguments; its class paths as -cp, its -L as -lib ndll:<dir>;
// - scoped: a missing hxml is an error.
// Each library once per build; -lib ndll:<dir> is passed on (as the shim
// passes it to the compiler, for its haxelib to answer: Libraries does).
// Scope.haxelib is the `haxelib` command lix puts on PATH: within a scope
// its shim (haxeshim's HaxelibCli: `path` from the scope), else haxelib
// itself (Haxelib). What is not haxeshim's:
// before haxelib (or the error), the caller's `other` (node_modules); the
// "version" is not looked at (the compiler is the one running); the class
// paths checked after resolution are the libraries', not the build's own.
class Scope {
	static inline var CONFIG_FILE = ".haxerc";
	static inline var SCOPE_VAR = "HAXESHIM_SCOPE";

	public final haxeshimRoot:String;
	public final isGlobal:Bool;
	public final scopeDir:String;
	public final scopeLibDir:String;
	public final configFile:String;
	// (Sys.getCwd's: with a trailing slash)
	public final cwd:String;
	public final haxelibRepo:String;
	public final libCache:String;
	public var resolveLibs(default, null):String;
	final env:String->Null<String>;

	function new(haxeshimRoot:String, isGlobal:Bool, scopeDir:String, cwd:String, env:String->Null<String>) {
		this.haxeshimRoot = haxeshimRoot;
		this.isGlobal = isGlobal;
		this.scopeDir = scopeDir;
		this.scopeLibDir = '$scopeDir/haxe_libraries';
		this.cwd = cwd;
		this.env = env;
		configFile = '$scopeDir/$CONFIG_FILE';
		haxelibRepo = '$haxeshimRoot/haxelib';
		libCache = switch [env("HAXESHIM_LIBCACHE"), env("HAXE_LIBCACHE")] {
			case [null, null]: '$haxeshimRoot/haxe_libraries';
			case [null, v] | [v, _]: v;
		}
	}

	// the scope of a build in cwd (Scope.seek); inherit: HAXESHIM_SCOPE's
	// (the shim drops it for a leading --cwd); null: none
	public static function seek(cwd:String, env:String->Null<String>, inherit = true):Null<Scope> {
		cwd = Path.addTrailingSlash(cwd);
		var inherited = nonEmpty(env(SCOPE_VAR));
		var startLookingIn = if (inherit && inherited != null) inherited else cwd;
		var root = defaultRoot(env);
		var ret = switch findNearest(CONFIG_FILE, FileSystem.absolutePath(startLookingIn)) {
			case null:
				// (the shim fails without a global .haxerc: here, no scope)
				if (!FileSystem.exists('$root/$CONFIG_FILE')) return null;
				new Scope(root, true, root, cwd, env);
			case v:
				new Scope(root, false, Path.directory(v), cwd, env);
		}
		ret.reload();
		return ret;
	}

	static function nonEmpty(s:Null<String>):Null<String>
		return s == null || s == "" ? null : s;

	static function defaultRoot(env:String->Null<String>):String {
		var v = nonEmpty(env("HAXE_ROOT"));
		if (v == null) v = nonEmpty(env("HAXESHIM_ROOT"));
		return if (v != null) v else env(Sys.systemName() == "Windows" ? "APPDATA" : "HOME") + "/haxe";
	}

	// (Fs.findNearest)
	static function findNearest(name:String, dir:String):Null<String> {
		while (true)
			if (FileSystem.exists('$dir/$name')) return '$dir/$name';
			else switch Path.directory(dir) {
				case same if (dir == same): return null;
				case parent: dir = parent;
			}
		return null;
	}

	function reload() {
		var src = try File.getContent(configFile) catch (e:Dynamic)
			throw new LibraryError(if (isGlobal) 'Global config file $configFile does not exist or cannot be opened' else 'Unable to open file $configFile because $e');
		var config:Dynamic = try haxe.Json.parse(src) catch (e:Dynamic) throw new LibraryError('Invalid JSON in file $configFile:\n\n$src\n\n$e');
		var r:Dynamic = config.resolveLibs;
		if (r == null) r = isGlobal ? "mixed" : "scoped";
		switch r {
			case "scoped" | "mixed" | "haxelib":
			case v:
				throw new LibraryError('invalid value $v for `resolveLibs` in $configFile');
		}
		resolveLibs = r;
	}

	// (getVar: the environment, then getDefault)
	public function getVar(variable:String):Null<String>
		return switch env(variable) {
			case null | "": getDefault(variable);
			case v: v;
		}

	function getDefault(variable:String):Null<String>
		return switch variable {
			case "HAXESHIM_LIBCACHE" | "HAXE_LIBCACHE": libCache;
			case "SCOPE_DIR": scopeDir;
			case "CWD": cwd;
			default: null;
		}

	public function libHxml(lib:String):String
		return '$scopeLibDir/$lib.hxml';

	// the environment haxelib runs with (HaxeInstallation.env)
	public function haxelibEnv(name:String):Null<String>
		return name == "HAXELIB_PATH" ? haxelibRepo : env(name);

	// (Args.interpolate)
	public static function interpolate(s:String, getVar:String->Null<String>):Outcome {
		if (s.indexOf("${") == -1) return Success(s);
		var ret = new StringBuf(), pos = 0;
		while (pos < s.length)
			switch s.indexOf("${", pos) {
				case -1:
					ret.addSub(s, pos);
					break;
				case v:
					ret.addSub(s, pos, v - pos);
					var start = v + 2;
					var end = switch s.indexOf("}", start) {
						case -1: return Failure('unclosed interpolation in $s');
						case v: v;
					}
					var name = s.substr(start, end - start);
					ret.add(switch getVar(name) {
						case null:
							return Failure('unknown variable $name');
						case v:
							if (v == "${" + name + "}") v else switch interpolate(v, getVar) {
								case Success(v): v;
								case failed: return failed;
							}
					});
					pos = end + 1;
			}
		return Success(ret.toString());
	}

	// (Args.fromMultilineString: lix's hxml, positions file:line from 0)
	public static function fromMultilineString(source:String, filename:String, getVar:String->Null<String>, errors:Array<Error>,
			liftClassPaths = false):Array<Arg> {
		var ret:Array<Arg> = [];
		var getVar = s -> if (s == "__dirname") Path.directory(filename) else getVar(s);
		function add(s:String, line:Int) {
			var pos = '$filename:$line';
			if (s.charAt(0) == "-") ret.push({val: s, pos: pos}) else switch interpolate(s, getVar) {
				case Success(v): ret.push({val: v, pos: pos});
				case Failure(e): errors.push({message: e, pos: pos});
			}
		}
		var lines = source.split("\n").map(StringTools.trim);
		for (number in 0...lines.length) {
			var line = lines[number];
			switch line.charAt(0) {
				case "-":
					switch line.indexOf(" ") {
						case -1:
							add(line, number);
						case v:
							add(line.substr(0, v), number);
							add(line.substr(v).trim(), number);
					}
				case "#":
				default:
					switch line.trim() {
						case "":
						case v:
							if (liftClassPaths) add("-cp", number);
							add(v, number);
					}
			}
		}
		return ret;
	}

	// a build's (one part's) resolution
	public function build():Build
		return new Build(this);

	// `haxelib <args>` in cwd, as the command lix puts on PATH answers:
	// within a scope its shim (lix's HaxelibCmd: the scope of cwd, sought
	// first; then HaxelibCli.exec: --cwd, which moves the process but not the
	// scope, --global, `path`), else haxelib (Haxelib.run); other:
	// Build.expand's, for a directory
	public static function haxelib(args:Array<String>, cwd:String, env:String->Null<String>, inherit:Bool,
			other:(dir:String) -> (String->Null<Array<String>>)):Haxelib.Output {
		// (Exec.die: the reason on stderr, the code as the exit code)
		function die(code:Int, reason:String):Haxelib.Output
			return {code: exitCode(code), stdout: "", stderr: reason + "\n"};
		var scope = try seek(cwd, env, inherit) catch (e:LibraryError) return die(500, e.message);
		if (scope == null) return Haxelib.run(args, cwd, env);
		// (parseGlobalPrefix)
		var i = 0, dir:Null<String> = null;
		while (i < args.length)
			switch args[i] {
				case "-cwd" | "--cwd":
					if (++i >= args.length) return die(500, '${args[i - 1]} requires argument');
					dir = args[i++];
				case "--global":
					i++;
				case arg if (arg.charCodeAt(0) == "-".code):
					return die(500, 'Global flag \'$arg\' is not supported by haxeshim; please report a bug');
				default:
					break;
			}
		var commandArgs = args.slice(i);
		// (Sys.setCwd)
		if (dir != null && !FileSystem.isDirectory(Path.isAbsolute(dir) ? dir : Path.join([cwd, dir]))) return die(500, 'Invalid directory: $dir');
		if (commandArgs[0] != "path") return die(1, 'hxmc: `haxelib ${args.join(" ")}` within lix\'s scope is only answered by lix itself');
		// (HaxelibCli.path)
		var libs = commandArgs.slice(1), names = [], out = [];
		for (lib in libs)
			if (lib.startsWith("ndll:")) out.push("-L " + lib.substr(5)) else names.push(lib.split(":")[0]);
		// (scope.resolve: the build's arguments, the class paths not checked; on
		// failure the first error's message on stdout, its code the exit code)
		var b = scope.build();
		b.checkClassPaths = false;
		var dirNoSlash = Path.removeTrailingSlashes(scope.cwd);
		var resolved = try {
			var a = b.expand(names, dirNoSlash, other(dirNoSlash));
			a.concat(b.finish());
		} catch (e:LibraryError) {
			var first = e.errors[0];
			return {code: exitCode(first.code != null ? first.code : 500), stdout: first.message + "\n", stderr: ""};
		}
		var i = 0;
		while (i < resolved.length) {
			switch resolved[i] {
				case "-lib":
					var v = resolved[++i];
					if (v != null && v.startsWith("ndll:")) out.push("-L " + v.substr(5)) else
						return {code: exitCode(500), stdout: 'Unexpected -lib $v returned from haxelib path ${libs.join(" ")}\n', stderr: ""};
				case "-cwd" | "--cwd":
					i++;
				// (-libcp: a class path from node_modules)
				case "-cp" | "-libcp":
					out.push(Path.addTrailingSlash(resolved[++i]));
				case v if (v.charCodeAt(0) == "-".code):
					out.push('$v ${resolved[++i]}');
				default:
			}
			i++;
		}
		// (Out.print: no newline at the end)
		return {code: 0, stdout: out.join("\n"), stderr: ""};
	}

	// (Sys.exit's code as the parent sees it: a byte, but on Windows)
	static function exitCode(code:Int):Int
		return Sys.systemName() == "Windows" ? code : code & 0xFF;
}

// (Scope.resolveArgs, for the -lib of one build)
class Build {
	final scope:Scope;
	final libs = new Map<String, Bool>();
	final haxelibs:Array<Arg> = [];
	final errors:Array<Error> = [];
	// the class paths the libraries added, with the directory they are relative to
	final classPaths:Array<{arg:Arg, cwd:String}> = [];
	// whether finish checks them (the shim's build does; its resolve-args does not)
	public var checkClassPaths = true;

	public function new(scope:Scope) {
		this.scope = scope;
	}

	// the arguments in the place of `-lib <name>` for each of names, in a
	// build in cwd; other: the arguments of a library from elsewhere, or null
	public function expand(names:Array<String>, cwd:String, other:String->Null<Array<String>>):Array<String> {
		var args:Array<Arg> = [];
		for (n in names) {
			args.push({val: "-lib", pos: null});
			args.push({val: n, pos: null});
		}
		var out:Array<Arg> = [];
		function resolvePath(p:String)
			return if (Path.isAbsolute(p)) p else Path.join([cwd, p]);
		while (args.length > 0) {
			var arg = args.shift();
			function fail(msg:String)
				errors.push({message: msg, pos: arg.pos});
			switch arg.val {
				case "-lib" | "--lib" | "-L" | "--library":
					switch args.shift() {
						case null:
							fail("-lib requires argument");
						case v if (v.val.startsWith("ndll:")):
							out.push(arg);
							out.push(v);
						case lib:
							if (!libs[lib.val]) {
								libs[lib.val] = true;
								function elsewhere(orElse:Void->Void)
									switch other(lib.val) {
										case null: orElse();
										case found: for (a in found) out.push({val: a, pos: lib.pos});
									}
								switch scope.resolveLibs {
									case "haxelib":
										elsewhere(() -> haxelibs.push(lib));
									case mode:
										var file = scope.libHxml(lib.val);
										switch readFile(file) {
											case Success(raw):
												args = Scope.fromMultilineString(raw, file, scope.getVar, errors).concat(args);
											case Failure(e):
												if (FileSystem.exists(file)) fail(e);
												else elsewhere(() -> if (mode == "mixed") haxelibs.push(lib) else fail('-lib ${lib.val} is missing $file'));
										}
								}
							}
					}
				case hxml if (hxml.endsWith(".hxml")):
					var path = resolvePath(hxml);
					switch readFile(path) {
						case Success(raw): args = Scope.fromMultilineString(raw, path, scope.getVar, errors).concat(args);
						case Failure(e): fail(e);
					}
				case forbidden = "--next" | "--each" | "--connect" | "--wait" | "--server-listen" | "--server-connect" | "--cwd" | "-C" | "--run":
					fail('$forbidden not allowed here');
					break;
				default:
					out.push(arg);
			}
		}
		addClassPaths(out, cwd);
		return [for (a in out) a.val];
	}

	// (ResolvedArgs.checkClassPaths's: the value after each -cp)
	function addClassPaths(args:Array<Arg>, cwd:String)
		for (i in 0...args.length) switch args[i].val {
			case "-cp" | "-p" | "--class-path" if (i + 1 < args.length):
				classPaths.push({arg: args[i + 1], cwd: cwd});
			default:
		}

	// the arguments after the build's: haxelib's libraries (resolveThroughHaxelib);
	// throws the build's errors
	public function finish():Array<String> {
		var out:Array<String> = [];
		if (haxelibs.length > 0) {
			var r = Haxelib.run(["path"].concat([for (l in haxelibs) l.val]), scope.cwd, scope.haxelibEnv);
			if (r.code == 0) {
				var args = Scope.fromMultilineString(r.stdout, "haxelib path", scope.getVar, errors, true);
				// (-L <dir>: -lib ndll:<dir>)
				for (i in 0...args.length)
					if (args[i].val == "-L" && i + 1 < args.length) {
						args[i] = {val: "-lib", pos: args[i].pos};
						args[i + 1] = {val: "ndll:" + args[i + 1].val, pos: args[i + 1].pos};
					}
				addClassPaths(args, scope.cwd);
				for (a in args) out.push(a.val);
			} else
				errors.push({message: r.stdout + r.stderr, pos: "haxelib path", code: r.code});
		}
		if (errors.length == 0 && checkClassPaths)
			// (ResolvedArgs.checkClassPaths)
			for (c in classPaths) {
				var p = if (Path.isAbsolute(c.arg.val)) c.arg.val else Path.join([c.cwd, c.arg.val]);
				try FileSystem.readDirectory(p) catch (_:Dynamic)
					errors.push({message: 'classpath ${c.arg.val} is not a directory or cannot be read from', pos: c.arg.pos});
			}
		if (errors.length > 0) throw LibraryError.of(errors);
		return out;
	}

	// (Scope.fs.readFile, with node's messages)
	static function readFile(path:String):Outcome
		return try Success(File.getContent(path)) catch (e:Dynamic) Failure('Cannot read $path because ' + if (!FileSystem.exists(path))
			'Error: ENOENT: no such file or directory, open \'$path\'' else if (FileSystem.isDirectory(path))
			"Error: EISDIR: illegal operation on a directory, read" else Std.string(e));
}

typedef Arg = {val:String, pos:Null<String>};
typedef Error = {message:String, pos:Null<String>, ?code:Int};

enum Outcome {
	Success(s:String);
	Failure(message:String);
}

// what the shim prints before it exits: each error's position and message
class LibraryError extends haxe.Exception {
	public final errors:Array<Error>;

	public function new(message:String, ?errors:Array<Error>) {
		super(message);
		this.errors = errors != null ? errors : [{message: message, pos: null}];
	}

	public static function of(errors:Array<Error>):LibraryError
		return new LibraryError([for (e in errors) e.pos == null ? e.message : '${e.pos}: ${e.message}'].join("\n"), errors);
}
