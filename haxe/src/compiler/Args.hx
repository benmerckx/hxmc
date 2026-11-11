package compiler;

import compiler.ParsedArg;
import compiler.ParsedArg.ParsedArgTools.createNativeLib;
import core.Globals.Platform;
import core.Globals as Globals;
import core.Define as Defines;
import core.Meta;
import core.Warning;
import context.Common;
import context.Common.CommonContext;
import core.ds.ArgumentError;
import core.ds.Failure;
import core.ds.NotFound;
import compiler.Helper.HelpMessage;

enum ServerMode {
	SMNone;
	SMListen(hostPort:String);
	SMConnect(hostPort:String);
}

// port: the (category, ok, dep, spec, hint, doc) tuples, without the never-invoked Arg.t spec.
typedef ArgDescription = {
	var category:String;
	var ok:Array<String>;
	var dep:Array<String>;
	var hint:String;
	var doc:String;
}

class Args {
	// port: Terminal_size.get_columns has no host API; $COLUMNS stands in for the terminal width.
	static var columns:Null<Int>;

	static function forceColumns():Int {
		if (columns == null) columns = switch Std.parseInt(Sys.getEnv("COLUMNS")) {
			case null: 80;
			case c: c;
		}
		return columns;
	}

	public static function limitString(s:String, offset:Int):String {
		var rest = forceColumns() - offset;
		// port: ExtString.String.nsplit (an empty string has no parts).
		var words = s == "" ? [] : s.split(" ");
		// port: the recursion over words, as a loop.
		var parts = [];
		var i = 0;
		for (word in words) {
			if (word.length + i + 1 > rest) {
				parts.push("\n" + StringTools.lpad("", " ", offset));
				parts.push(word);
				i = word.length;
			} else {
				parts.push(if (i == 0) "" else " ");
				parts.push(word);
				i = i + 1 + word.length;
			}
		}
		return parts.join("");
	}

	public static function usageString(argSpec:Array<ArgDescription>, usage:String, printCat:Bool = true):String {
		var makeLabel = function(names:Array<String>, hint:String) return names.join(", ") + " " + hint;
		var args = argSpec.filter(a -> a.ok.length > 0);
		var catOrder = [
			"Target",
			"Compilation",
			"Optimization",
			"Debug",
			"Batch",
			"Services",
			"Compilation Server",
			"Target-specific",
			"Miscellaneous"
		];
		var argCats = args.map(a -> a.category);
		var cats = catOrder.filter(x -> argCats.contains(x));
		var maxLength = 0;
		for (a in args) {
			var l = makeLabel(a.ok, a.hint).length;
			if (l > maxLength) maxLength = l;
		}
		var lines = [];
		for (cat in cats) {
			if (printCat) lines.push("\n" + cat + ":");
			for (a in args.filter(a -> (if (catOrder.contains(a.category)) a.category else "Miscellaneous") == cat)) {
				var label = makeLabel(a.ok, a.hint);
				lines.push("  " + label + StringTools.lpad("", " ", maxLength - label.length) + "  " + a.doc);
			}
		}
		return usage + lines.join("\n");
	}

	/** Static arg descriptions used for generating help strings via [usage_string].
		[usage_string] only reads the category, primary-flag names, hint, and doc
		fields — the [Arg.t] value is never invoked, so [Arg.Unit ignore] is used
		everywhere.  Entries with an empty primary-flag list ([ok = []]) are already
		filtered out by [usage_string], so they are omitted here. */
	static final basicArgsDescriptions:Array<ArgDescription> = [
		{category: "Target", ok: ["--js"], dep: ["-js"], hint: "<file>", doc: "generate JavaScript code into target file"},
		{category: "Target", ok: ["--lua"], dep: ["-lua"], hint: "<file>", doc: "generate Lua code into target file"},
		{category: "Target", ok: ["--swf"], dep: ["-swf"], hint: "<file>", doc: "generate Flash SWF bytecode into target file"},
		{category: "Target", ok: ["--neko"], dep: ["-neko"], hint: "<file>", doc: "generate Neko bytecode into target file"},
		{category: "Target", ok: ["--php"], dep: ["-php"], hint: "<directory>", doc: "generate PHP code into target directory"},
		{category: "Target", ok: ["--cpp"], dep: ["-cpp"], hint: "<directory>", doc: "generate C++ code into target directory"},
		{category: "Target", ok: ["--cppia"], dep: ["-cppia"], hint: "<file>", doc: "generate Cppia bytecode into target file"},
		{category: "Target", ok: ["--jvm"], dep: ["-jvm"], hint: "<file>", doc: "generate JVM bytecode into target file"},
		{category: "Target", ok: ["--python"], dep: ["-python"], hint: "<file>", doc: "generate Python code into target file"},
		{category: "Target", ok: ["--hl"], dep: ["-hl"], hint: "<file>", doc: "generate HashLink .hl bytecode or .c code into target file"},
		{category: "Target", ok: ["--custom-target"], dep: ["-custom"], hint: "<name[=path]>", doc: "generate code for a custom target"},
		{category: "Target", ok: ["--interp"], dep: [], hint: "", doc: "interpret the program using internal macro system"},
		{category: "Target", ok: ["--run"], dep: [], hint: "<module> [args...]", doc: "interpret a Haxe module with command line arguments"},
		{category: "Compilation", ok: ["-p", "--class-path"], dep: ["-cp"], hint: "<path>", doc: "add a directory to find source files"},
		{category: "Compilation", ok: ["--hxb-lib"], dep: ["-hxb-lib"], hint: "<path>", doc: "add a hxb library"},
		{category: "Compilation", ok: ["-m", "--main"], dep: ["-main"], hint: "<class>", doc: "select startup class"},
		{category: "Compilation", ok: ["-L", "--library"], dep: ["-lib"], hint: "<name[:ver]>", doc: "use a haxelib library"},
		{category: "Compilation", ok: ["-D", "--define"], dep: [], hint: "<var[=value]>", doc: "define a conditional compilation flag"},
		{category: "Compilation", ok: ["--undefine"], dep: [], hint: "<var>", doc: "remove a conditional compilation flag"},
		{category: "Debug", ok: ["-v", "--verbose"], dep: [], hint: "", doc: "turn on verbose mode"},
		{category: "Debug", ok: ["--debug"], dep: ["-debug"], hint: "", doc: "add debug information to the compiled code"},
		{category: "Miscellaneous", ok: ["--version"], dep: ["-version"], hint: "", doc: "print version and exit"},
		{category: "Miscellaneous", ok: ["-h", "--help"], dep: ["-help"], hint: "", doc: "show extended help information"},
		{category: "Miscellaneous", ok: ["--help-defines"], dep: [], hint: "", doc: "print help for all compiler specific defines"},
		{category: "Miscellaneous", ok: ["--help-user-defines"], dep: [], hint: "", doc: "print help for all user defines"},
		{category: "Miscellaneous", ok: ["--help-metas"], dep: [], hint: "", doc: "print help for all compiler metadatas"},
		{category: "Miscellaneous", ok: ["--help-user-metas"], dep: [], hint: "", doc: "print help for all user metadatas"},
	];

	static final advArgsDescriptions:Array<ArgDescription> = [
		{category: "Optimization", ok: ["--dce"], dep: ["-dce"], hint: "[std|full|no]", doc: "set the dead code elimination mode (default std)"},
		{category: "Target-specific", ok: ["--swf-version"], dep: ["-swf-version"], hint: "<version>", doc: "change the SWF version"},
		{category: "Target-specific", ok: ["--swf-lib"], dep: ["-swf-lib"], hint: "<file>", doc: "add the SWF library to the compiled SWF"},
		{category: "Target-specific", ok: ["--swf-lib-extern"], dep: ["-swf-lib-extern"], hint: "<file>", doc: "use the SWF library for type checking"},
		{category: "Target-specific", ok: ["--java-lib"], dep: ["-java-lib"], hint: "<file>", doc: "add an external JAR or directory of JAR files"},
		{category: "Target-specific", ok: ["--java-lib-extern"], dep: [], hint: "<file>", doc: "use an external JAR or directory of JAR files for type checking"},
		{category: "Compilation", ok: ["-r", "--resource"], dep: ["-resource"], hint: "<file>[@name]", doc: "add a named resource file"},
		{category: "Debug", ok: ["--prompt"], dep: ["-prompt"], hint: "", doc: "prompt on error"},
		{category: "Compilation", ok: ["--cmd"], dep: ["-cmd"], hint: "<command>", doc: "run the specified command after successful compilation"},
		{category: "Batch", ok: ["--next"], dep: [], hint: "", doc: "separate several haxe compilations"},
		{category: "Batch", ok: ["--each"], dep: [], hint: "", doc: "append preceding parameters to all Haxe compilations separated by --next"},
		{category: "Services", ok: ["--display"], dep: [], hint: "", doc: "display code tips"},
		{category: "Services", ok: ["--xml"], dep: ["-xml"], hint: "<file>", doc: "generate XML types description"},
		{category: "Services", ok: ["--json"], dep: [], hint: "<file>", doc: "generate JSON types description"},
		{category: "Services", ok: ["--hxb"], dep: [], hint: "<file>", doc: "generate haxe binary representation to target archive"},
		{category: "Optimization", ok: ["--no-output"], dep: [], hint: "", doc: "compiles but does not generate any file"},
		{category: "Debug", ok: ["--times"], dep: [], hint: "", doc: "measure compilation times"},
		{category: "Compilation", ok: ["--remap"], dep: [], hint: "<package:target>", doc: "remap a package to another one"},
		{category: "Compilation", ok: ["--custom-extension"], dep: [], hint: "<extension>", doc: "custom extension used to shadow modules with Module.custom.hx files"},
		{category: "Compilation", ok: ["--macro"], dep: [], hint: "<macro>", doc: "call the given macro before typing anything else"},
		{category: "Compilation Server", ok: ["--server-listen"], dep: ["--wait"], hint: "[[host:]port]|stdio]", doc: "wait on the given port (or use standard i/o) for commands to run"},
		{category: "Compilation Server", ok: ["--server-connect"], dep: [], hint: "[host:]port]", doc: "connect to the given port and wait for commands to run"},
		{category: "Compilation Server", ok: ["--connect"], dep: [], hint: "<[host:]port>", doc: "connect on the given port and run commands there"},
		{category: "Compilation", ok: ["-C", "--cwd"], dep: [], hint: "<directory>", doc: "set current working directory"},
		{category: "Compilation", ok: ["--haxelib-global"], dep: [], hint: "", doc: "pass --global argument to haxelib"},
		{category: "Compilation", ok: ["-w"], dep: [], hint: "<warning list>", doc: "enable or disable specific warnings"},
	];

	/** Expand [%VAR%] environment variable references in compiler arguments.
		The [--display] argument is left alone, and so is everything after
		[--run <module>] because those are runtime arguments for the program. */
	static function expandEnvArgs(args:Array<String>):Array<String> {
		// port: the recursion over the list as a loop.
		var acc = [];
		var i = 0;
		while (i < args.length) {
			switch args[i] {
				case "--display" if (i + 1 < args.length):
					acc.push("--display");
					acc.push(args[i + 1]);
					i += 2;
				case "--run" if (i + 1 < args.length):
					acc.push("--run");
					acc.push(Helper.expandEnv(args[i + 1]));
					return acc.concat(args.slice(i + 2));
				case arg:
					acc.push(Helper.expandEnv(arg));
					i++;
			}
		}
		return acc;
	}

	// port: Path.parse_type_path raises its failwith message as a String; rethrown as Failure.
	static function parseTypePath(cl:String):Array<String> {
		var path = try core.Path.parseTypePath(cl) catch (msg:String) throw new Failure(msg);
		return path.pack.concat([path.name]);
	}

	/** Pre-parse a flat string list into a [parsed_arg list].
		This does NOT expand hxml files (they become [HxmlFile] markers) and does
		NOT call out to haxelib (libraries become [AddLib] markers). Both are
		handled lazily when the request is later processed.

		The translation is mostly 1-to-1: one CLI flag group → one [parsed_arg].
		Compound expansions (e.g. adding [php.Boot] for [--php], setting
		[actx.interp] for [--interp]) are deferred to [process_args]. */
	public static function parseArgs(args:Array<String>):Array<ParsedArg> {
		var parsed:Array<ParsedArg> = [];
		function add(a:ParsedArg) parsed.push(a);
		var args = expandEnvArgs(args);
		// port: the list match `flag :: x :: rest` as a guard on the next token; a flag without its
		// value falls through to the final `arg :: rest` case, as upstream.
		var i = 0;
		while (i < args.length) {
			var hasValue = i + 1 < args.length;
			var value = hasValue ? args[i + 1] : null;
			switch args[i] {
				case "--next" | "-next":
					add(Next);
					i += 1;
				case "--each" | "-each":
					add(Each);
					i += 1;
				case "--cwd" | "-C" if (hasValue):
					add(Cwd(value));
					i += 2;
				case "--js" | "-js" if (hasValue):
					add(SetPlatform(Js, value));
					i += 2;
				case "--lua" | "-lua" if (hasValue):
					add(SetPlatform(Lua, value));
					i += 2;
				case "--swf" | "-swf" if (hasValue):
					add(SetPlatform(Flash, value));
					i += 2;
				case "--neko" | "-neko" if (hasValue):
					add(SetPlatform(Neko, value));
					i += 2;
				case "--php" | "-php" if (hasValue):
					add(SetPlatform(Php, value));
					i += 2;
				case "--cpp" | "-cpp" if (hasValue):
					add(SetPlatform(Cpp, value));
					i += 2;
				case "--cppia" | "-cppia" if (hasValue):
					add(SetCppiaTarget(value));
					i += 2;
				case "--jvm" | "-jvm" if (hasValue):
					add(SetPlatform(Jvm, value));
					add(AddLib("hxjava"));
					i += 2;
				case "--python" | "-python" if (hasValue):
					add(SetPlatform(Python, value));
					i += 2;
				case "--hl" | "-hl" if (hasValue):
					add(SetPlatform(Hl, value));
					i += 2;
				case "--custom-target" | "-custom" if (hasValue):
					var target = value;
					// port: ExtString.String.split at the first "=", Invalid_string when absent.
					var name, path;
					switch target.indexOf("=") {
						case -1:
							name = target;
							path = "";
						case k:
							name = target.substr(0, k);
							path = target.substr(k + 1);
					}
					add(SetCustomTarget(name, path));
					i += 2;
				case "-x" if (hasValue):
					// -x is non-terminal: subsequent args remain build args
					add(RunX(value));
					i += 2;
				case "--interp":
					add(Interp);
					i += 1;
				case "--run" if (hasValue):
					add(Run(value, args.slice(i + 2)));
					// --run consumes all remaining tokens as runtime args
					break;
				case "--class-path" | "-p" | "-cp" if (hasValue):
					add(AddClassPath(value));
					i += 2;
				case "-libcp" if (hasValue):
					add(AddLibClassPath(value, null));
					i += 2;
				case "-libcp-of" if (i + 2 < args.length):
					add(AddLibClassPath(args[i + 2], value));
					i += 3;
				case "--hxb-lib" | "-hxb-lib" if (hasValue):
					add(AddHxbLib(value));
					i += 2;
				case "--main" | "-m" | "-main" if (hasValue):
					var cpath = parseTypePath(value);
					add(SetMain(cpath));
					i += 2;
				case "--library" | "-L" | "-lib" if (hasValue):
					add(AddLib(value));
					i += 2;
				case "--define" | "-D" if (hasValue):
					var v = value;
					var flag, value:Null<String>;
					switch v.indexOf("=") {
						case -1:
							flag = v;
							value = null;
						case k:
							flag = v.substr(0, k);
							value = v.substr(k + 1);
					}
					add(Define(flag, value));
					i += 2;
				case "--undefine" if (hasValue):
					add(Undefine(value));
					i += 2;
				case "--verbose" | "-v":
					add(SetVerbose);
					i += 1;
				case "--debug" | "-debug":
					add(SetDebug);
					i += 1;
				case "--version" | "-version":
					add(ShowVersion);
					// consume remaining args - ShowVersion raises immediately in process_args
					break;
				case "--help" | "-h" | "-help":
					add(ShowHelp);
					break;
				case "--help-defines":
					add(ShowHelpDefines);
					break;
				case "--help-metas":
					add(ShowHelpMetas);
					break;
				case "--help-user-defines":
					add(ShowHelpUserDefines);
					break;
				case "--help-user-metas":
					add(ShowHelpUserMetas);
					break;
				case "--dce" | "-dce" if (hasValue):
					add(SetDce(value));
					i += 2;
				case "--swf-version" | "-swf-version" if (hasValue):
					try add(SetSwfVersion(core.ds.OcamlFloat.ofString(value))) catch (_:Dynamic) {}
					i += 2;
				case "--swf-lib" | "-swf-lib" if (hasValue):
					add(AddNativeLib(createNativeLib(value, false, SwfLib)));
					i += 2;
				case "--neko-lib-path" if (hasValue):
					add(AddNekoLibPath(value));
					i += 2;
				case "--swf-lib-extern" | "-swf-lib-extern" if (hasValue):
					add(AddNativeLib(createNativeLib(value, true, SwfLib)));
					i += 2;
				case "--java-lib" | "-java-lib" if (hasValue):
					add(AddNativeLib(createNativeLib(value, false, JavaLib)));
					i += 2;
				case "--java-lib-extern" if (hasValue):
					add(AddNativeLib(createNativeLib(value, true, JavaLib)));
					i += 2;
				case "--resource" | "-r" | "-resource" if (hasValue):
					// port: ExtString.String.nsplit res "@"
					switch (value == "" ? [] : value.split("@")) {
						case [file, name]: add(AddResource(file, name));
						case [file]: add(AddResource(file, file));
						case _:
					}
					i += 2;
				case "--prompt" | "-prompt":
					add(SetPrompt);
					i += 1;
				case "--cmd" | "-cmd" if (hasValue):
					add(RunCmd(Helper.unquote(value)));
					i += 2;
				case "--display" if (hasValue):
					add(SetDisplayArg(value));
					i += 2;
				case "--xml" | "-xml" if (hasValue):
					add(SetXmlOut(value));
					i += 2;
				case "--json" if (hasValue):
					add(SetJsonOut(value));
					i += 2;
				case "--hxb" if (hasValue):
					add(SetHxbOut(value));
					i += 2;
				case "--no-output":
					add(SetNoOutput);
					i += 1;
				case "--times":
					add(SetMeasureTimes);
					i += 1;
				case "--remap" | "-remap" if (hasValue):
					switch value.indexOf(":") {
						case -1:
						case k: add(Remap(value.substr(0, k), value.substr(k + 1)));
					}
					i += 2;
				case "--custom-extension" if (hasValue):
					add(SetCustomExtension(value));
					i += 2;
				case "--macro" | "-macro" if (hasValue):
					add(AddMacro(value));
					i += 2;
				case "--server-listen" | "--wait" if (hasValue):
					add(ServerListen(value));
					i += 2;
				case "--server-connect" if (hasValue):
					add(ServerConnect(value));
					i += 2;
				case "--connect" if (hasValue):
					add(Connect(value));
					i += 2;
				case "--haxelib-global":
					add(HaxelibGlobal);
					i += 1;
				case "-w" if (hasValue):
					add(AddWarning(value));
					i += 2;
				case arg:
					// port: List.rev (ExtString.String.nsplit arg ".")
					var parts = arg == "" ? [] : arg.split(".");
					if (parts.length >= 2 && parts[parts.length - 1] == "hxml") {
						add(HxmlFile(arg));
					} else {
						var path = try core.Path.parsePath(arg) catch (_:core.ds.Failure) null;
						if (path == null) add(IncludeModule(arg));
						else if (core.StringHelper.startsUppercaseIdentifier(path.name)) add(AddClass(path.pack.concat([path.name])));
						else add(IncludeModule(arg));
					}
					i += 1;
			}
		}
		return parsed;
	}

	/** Apply a single-part [parsed_arg list] to [com], returning the populated
		[arg_context].  Higher-level concerns ([Next], [Each], [AddLib] expansion,
		hxml expansion) are handled by [Compiler.HighLevel.process_params]. */
	public static function processArgs(com:CommonContext):ArgContext {
		var actx:ArgContext = {
			classes: [{pack: [], name: "Std"}],
			xmlOut: null,
			hxbOut: null,
			jsonOut: null,
			cmds: [],
			configMacros: [],
			noOutput: false,
			didSomething: false,
			forceTyping: false,
			preCompilation: [],
			interp: false,
			jvmFlag: false,
			swfVersion: false,
			hxbLibs: [],
			nativeLibs: [],
			raiseUsage: function() {},
			displayArg: null,
			measureTimes: false
		};
		var usage = "Haxe Compiler " + Globals.sVersionFull(com.sctx.version) + " - (C)2005-2025 Haxe Foundation\nUsage: haxe"
			+ (if (Sys.systemName() == "Windows") ".exe" else "") + " <target> [options] [hxml files and dot paths...]\n";
		// port: the List.map (fun (n,doc) -> Printf.sprintf " %-*s: %s" ...) shared by the four help listings.
		function docList(r:{all:Array<{name:String, description:String}>, maxLength:Int}):String {
			var maxLength = r.maxLength;
			var all = r.all.map(d -> " " + StringTools.rpad(d.name, " ", maxLength) + ": " + limitString(d.description, maxLength + 3));
			return all.join("\n");
		}
		// port: `path` values are flat lists (see ParsedArg.SetMain).
		function toPath(parts:Array<String>):core.Globals.GlobalTypePath return {pack: parts.slice(0, -1), name: parts[parts.length - 1]};
		function processOne(arg:ParsedArg) switch arg {
			case SetPlatform(platform, file):
				switch platform {
					case Php:
						// --php also adds the php.Boot class
						actx.classes.unshift({pack: ["php"], name: "Boot"});
					case Jvm:
						// --jvm also sets the jvm_flag
						actx.jvmFlag = true;
					case _:
				}
				Common.setPlatform(com, platform, file);
			case SetCppiaTarget(file):
				// --cppia: enable cppia define and target cpp
				Common.define(com, Defines.Cppia);
				Common.setPlatform(com, Cpp, file);
			case SetCustomTarget(name, path):
				Common.setCustomTarget(com, name, path);
			case AddClassPath(path):
				com.classPaths.add(new core.ClassPath.DirectoryClassPath(core.Path.addTrailingSlash(path), User));
			case AddLibClassPath(path, name):
				com.classPaths.add(new core.ClassPath.DirectoryClassPath(core.Path.addTrailingSlash(path), Lib(name)));
			case AddHxbLib(file):
				actx.hxbLibs.unshift(createNativeLib(file, false, HxbLib));
			case SetMain(cpath):
				if (com.main.mainPath != null) throw new ArgumentError("Multiple --main classes specified");
				var cpath = toPath(cpath);
				com.main.mainPath = cpath;
				// --main also adds the class for compilation (matches old parse_args behaviour)
				actx.classes.unshift(cpath);
			case AddLib(_) | HaxelibGlobal:
				// handled at the process_params level
			case Define(flag, value):
				switch value {
					case null: Common.externalDefine(com, flag);
					case v: Common.externalDefineValue(com, flag, v);
				}
				// --no-opt also disables the foptimize flag (mirroring parse_args behavior)
				if (flag == "no-opt") com.foptimize = false;
			case Undefine(v):
				Common.externalUndefine(com, v);
			case SetVerbose:
				com.verbose = true;
			case SetDebug:
				Common.define(com, Defines.Debug);
				com.debug = true;
			case Interp:
				// --interp: define interp, set eval platform, mark actx.interp
				Common.define(com, Defines.Interp);
				Common.setPlatform(com, Eval, "");
				actx.interp = true;
			case Run(_) | RunX(_):
				// --run / -x: handled at process_params level
			case AddResource(file, name):
				var file = try Common.findFile(com, file) catch (_:NotFound) file;
				var data = try {
					var s = sys.io.File.getBytes(file);
					if (s.length > 12000000) throw core.ds.Exit.raise();
					s;
				} catch (e:core.ds.Exit) {
					throw new Failure("Resource '" + file + "' excess the maximum size of 12MB");
				} catch (_:Dynamic) {
					// port: Std.input_file raises Sys_error for an unreadable file.
					throw new Failure("Resource file not found: " + file);
				}
				if (com.resources.mem(name)) throw new Failure("Duplicate resource name " + name);
				com.resources.add(name, data);
			case RunCmd(cmd):
				actx.cmds.unshift(cmd);
			case SetSwfVersion(v):
				if (!actx.swfVersion || com.flashVersion < v) com.flashVersion = v;
				actx.swfVersion = true;
			case SetDce(mode):
				switch mode {
					case "std" | "full" | "no":
					case _: throw new ArgumentError("Invalid DCE mode, expected std | full | no");
				}
				Common.defineValue(com, Defines.Dce, mode);
			case AddNativeLib(lib):
				actx.nativeLibs.unshift(lib);
			case AddNekoLibPath(dir):
				com.nekoLibPaths.unshift(dir);
			case Remap(pack, target):
				// port: PMap.add on the persistent package_rules.
				var rules = com.packageRules.copy();
				rules.set(pack, context.Common.PackageRule.Remap(target));
				com.packageRules = rules;
			case SetCustomExtension(ext):
				com.customExt = ext;
			case AddMacro(e):
				actx.forceTyping = true;
				actx.configMacros.unshift(e);
			case SetDisplayArg(input):
				actx.displayArg = input;
			case SetXmlOut(file):
				actx.xmlOut = file;
			case SetJsonOut(file):
				actx.jsonOut = file;
			case SetHxbOut(file):
				actx.hxbOut = file;
			case SetNoOutput:
				actx.noOutput = true;
			case SetMeasureTimes:
				actx.measureTimes = true;
			case AddWarning(s):
				var p = Globals.fakePos("-w " + s);
				var l = Warning.parseOptions(s, p);
				com.warningOptions.unshift(l);
			case AddClass(cpath):
				actx.classes.unshift(toPath(cpath));
			case IncludeModule(cl):
				actx.forceTyping = true;
				actx.configMacros.unshift("include('" + cl + "', true, null, null, true)");
			case SetPrompt:
				Helper.prompt = true;
			case Cwd(dir):
				// Re-apply chdir: process_params applies it eagerly for hxml resolution,
				// but entry restores the original cwd before execute_ctx, so we must
				// re-apply here to compile in the right directory.
				try Sys.setCwd(dir) catch (_:Dynamic) throw new ArgumentError("Invalid directory: " + dir);
				actx.didSomething = true;
			case HxmlFile(_):
				// hxml files should have been expanded before reaching process_args
			case Next | Each | Expand(_):
				// batch directives handled at process_params level
			case ServerListen(_) | ServerConnect(_) | Connect(_):
				// server modes handled at process_params level
			case ShowVersion:
				throw new HelpMessage(Globals.sVersionFull(com.sctx.version));
			case ShowHelp:
				throw new HelpMessage(usageString(basicArgsDescriptions.concat(advArgsDescriptions), usage));
			case ShowHelpDefines:
				throw new HelpMessage(docList(Defines.getDocumentationList(com.userDefines)));
			case ShowHelpMetas:
				throw new HelpMessage(docList(Meta.getDocumentationList(com.userMetas)));
			case ShowHelpUserDefines:
				actx.didSomething = true;
				com.callbacks.addAfterInitMacros(function() {
					throw new HelpMessage(docList(Defines.getUserDocumentationList(com.userDefines)));
				});
			case ShowHelpUserMetas:
				actx.didSomething = true;
				com.callbacks.addAfterInitMacros(function() {
					throw new HelpMessage(docList(Meta.getUserDocumentationList(com.userMetas)));
				});
		}
		for (arg in (com.parsedArgs : Array<ParsedArg>)) processOne(arg);
		if (com.platform == Platform.Cpp
			&& !Defines.defined(com.defines, Defines.DisableUnicodeStrings)
			&& !Defines.defined(com.defines, Defines.HxcppSmartStrings)) Defines.define(com.defines, Defines.HxcppSmartStrings);
		if (Defines.rawDefined(com.defines, "gen_hx_classes")) {
			actx.forceTyping = true;
			actx.preCompilation.unshift(function() {
				function processLib(lib:context.NativeLibraries.NativeLibrary<Dynamic, Dynamic>) {
					if (!lib.hasFlag(context.NativeLibraries.NativeLibFlags.FlagIsStd))
						for (path in lib.listModules())
							if (!(path.pack.length == 2 && path.pack[0] == "java" && path.pack[1] == "lang" && path.name == "String"))
								actx.classes.unshift(path);
				}
				for (lib in com.nativeLibs.swfLibs) processLib(cast lib);
				for (lib in com.nativeLibs.javaLibs) processLib(cast lib);
			});
			actx.xmlOut = "hx";
		}
		actx.raiseUsage = function() {
			throw new HelpMessage(usageString(basicArgsDescriptions, usage));
		};
		return actx;
	}

	/** Serialize a [parsed_arg list] back to CLI tokens for the [--connect] wire
		protocol.  Each variant is mapped to the string(s) a user would type.
		This is used to forward a client's arguments to a remote compilation server. */
	public static function toRawArgs(parsedArgs:Array<ParsedArg>):Array<String> {
		function sPlatform(p:Platform) return switch p {
			case Cross: "cross";
			case Js: "js";
			case Lua: "lua";
			case Neko: "neko";
			case Flash: "swf";
			case Php: "php";
			case Cpp: "cpp";
			case Jvm: "jvm";
			case Python: "python";
			case Hl: "hl";
			case Eval: "eval";
			case CustomTarget(name): name;
		}
		function sPath(p:Array<String>) return p.join(".");
		function toRaw(arg:ParsedArg):Array<String> return switch arg {
			case SetPlatform(platform, file): ["--" + sPlatform(platform), file];
			case SetCppiaTarget(file): ["--cppia", file];
			case SetCustomTarget(name, path): ["--custom-target", if (path == "") name else name + "=" + path];
			case AddClassPath(path): ["-cp", path];
			case AddLibClassPath(path, null): ["-libcp", path];
			case AddLibClassPath(path, name): ["-libcp-of", name, path];
			case AddHxbLib(file): ["--hxb-lib", file];
			case SetMain(p): ["--main", sPath(p)];
			case AddLib(name): ["-lib", name];
			case HaxelibGlobal: ["--haxelib-global"];
			case Define(flag, null): ["-D", flag];
			case Define(flag, value): ["-D", flag + "=" + value];
			case Undefine(v): ["--undefine", v];
			case SetVerbose: ["-v"];
			case SetDebug: ["--debug"];
			case Interp: ["--interp"];
			case Run(cl, _): ["--run", cl];
			case RunX(cl): ["-x", cl];
			case AddResource(file, name):
				if (file == name) ["-r", file] else ["-r", file + "@" + name];
			case RunCmd(cmd): ["--cmd", cmd];
			case SetSwfVersion(v): ["--swf-version", core.Numeric.stringOfFloat(v)];
			case SetDce(mode): ["--dce", mode];
			case AddNativeLib({libFile: libFile, libExtern: false, libKind: SwfLib}): ["--swf-lib", libFile];
			case AddNativeLib({libFile: libFile, libExtern: true, libKind: SwfLib}): ["--swf-lib-extern", libFile];
			case AddNativeLib({libFile: libFile, libExtern: false, libKind: JavaLib}): ["--java-lib", libFile];
			case AddNativeLib({libFile: libFile, libExtern: true, libKind: JavaLib}): ["--java-lib-extern", libFile];
			case AddNativeLib(_): [];
			case AddNekoLibPath(dir): ["--neko-lib-path", dir];
			case Remap(pack, target): ["--remap", pack + ":" + target];
			case SetCustomExtension(ext): ["--custom-extension", ext];
			case AddMacro(e): ["--macro", e];
			case SetDisplayArg(input): ["--display", input];
			case SetXmlOut(file): ["--xml", file];
			case SetJsonOut(file): ["--json", file];
			case SetHxbOut(file): ["--hxb", file];
			case SetNoOutput: ["--no-output"];
			case SetMeasureTimes: ["--times"];
			case AddWarning(s): ["-w", s];
			case AddClass(p): [sPath(p)];
			case IncludeModule(cl): [cl];
			case SetPrompt: ["--prompt"];
			case Next: ["--next"];
			case Each: ["--each"];
			case Expand(ex): concatMap(toRaw, ex.original);
			case ServerListen(hp): ["--wait", hp];
			case ServerConnect(hp): ["--server-connect", hp];
			case Connect(hp): ["--connect", hp];
			case Cwd(dir): ["--cwd", dir];
			case HxmlFile(path): [path];
			case ShowVersion: ["--version"];
			case ShowHelp: ["--help"];
			case ShowHelpDefines: ["--help-defines"];
			case ShowHelpMetas: ["--help-metas"];
			case ShowHelpUserDefines: ["--help-user-defines"];
			case ShowHelpUserMetas: ["--help-user-metas"];
		}
		return concatMap(toRaw, parsedArgs);
	}

	static function concatMap<A, B>(f:A->Array<B>, l:Array<A>):Array<B> {
		var out = [];
		for (x in l) for (y in f(x)) out.push(y);
		return out;
	}

	static function expandArgsImpl(args:Array<ParsedArg>):RequestArgs {
		var each:Array<ParsedArg> = [];
		var parts:Array<PartArgs> = [];
		var serverMode:ServerMode = SMNone;
		var connectArg:Null<String> = null;
		var displayArg:Null<String> = null;
		var hxmlStack:Array<String> = [];
		function addPart(args:Array<ParsedArg>, runtimeArgs:Array<String>) {
			parts.push({args: each.concat(args), runtimeArgs: runtimeArgs});
		}
		// port: `current` is kept in order (upstream accumulates it reversed and reverses it in add_part),
		// and the tail recursion over the argument list is a loop over an index.
		var current:Array<ParsedArg> = [];
		var args = args.copy();
		var i = 0;
		while (true) {
			if (i >= args.length) {
				addPart(current, []);
				break;
			}
			switch args[i++] {
				case Next if (current.length == 0):
					// reset hxml_stack so the same hxml can be included in a subsequent section
					hxmlStack = [];
				case Next:
					addPart(current, []);
					// reset hxml_stack so the same hxml can be included in a subsequent section
					hxmlStack = [];
					current = [];
				case Each:
					each = current;
					current = [];
				case Cwd(dir):
					try Sys.setCwd(dir) catch (_:Dynamic) {}
					current.push(Cwd(dir));
				case Connect(hp):
					connectArg = hp;
				case ServerConnect(hp):
					serverMode = SMConnect(hp);
				case ServerListen(hp):
					serverMode = SMListen(hp);
				case Run(cl, runtimeArgs):
					var cpath = parseTypePath(cl);
					current.push(SetMain(cpath));
					current.push(Interp);
					var runtimeArgs = runtimeArgs.concat(toRawArgs(args.slice(i)));
					addPart(current, runtimeArgs);
					break;
				case RunX(cl):
					var cpath = parseTypePath(cl);
					current.push(SetMain(cpath));
					current.push(Interp);
				case AddLib(name):
					// find_subsequent_libs
					var libs = [name];
					while (i < args.length) switch args[i] {
						case AddLib(name):
							libs.push(name);
							i++;
						case _:
							break;
					}
					var ex = new ExpandingArg(libs.map(name -> AddLib(name)),
						// port: Sys.getCwd has a trailing slash that Unix.getcwd lacks.
						NotYetExpanded(AddLibs(libs, core.Path.removeTrailingSlash(Sys.getCwd()))));
					current.push(Expand(ex));
				case HxmlFile(path):
					// port: Extc.get_full_path (realpath) fails on a missing file.
					var fullPath = try sys.FileSystem.fullPath(path) catch (_:Dynamic) null;
					if (fullPath == null) throw new ArgumentError("File not found: " + path);
					if (hxmlStack.contains(fullPath))
						throw new ArgumentError("Duplicate hxml inclusion: " + fullPath)
					else
						hxmlStack.unshift(fullPath);
					var expanded = try {
						var raw = Helper.parseHxml(path);
						parseArgs(raw);
					} catch (_:NotFound) {
						[IncludeModule(path + " (file not found)")];
					}
					args = expanded.concat(args.slice(i));
					i = 0;
				case SetDisplayArg(s):
					displayArg = s;
					current.push(SetDisplayArg(s));
				case arg:
					current.push(arg);
			}
		}
		return {
			parts: parts,
			serverMode: serverMode,
			connectArg: connectArg,
			displayArg: displayArg
		};
	}

	public static function expandArgs(args:Array<ParsedArg>):RequestArgs {
		var curdir = Sys.getCwd();
		// port: Std.finally
		var result = try expandArgsImpl(args) catch (e:Dynamic) {
			core.Path.restoreCwd(curdir);
			throw e;
		}
		core.Path.restoreCwd(curdir);
		return result;
	}

	public static function stringOfRequestArgs(req:RequestArgs):String {
		function quote(s:String):String {
			// quote arguments that contain whitespace for clearer output
			return if (s.indexOf(" ") >= 0 || s.indexOf("\t") >= 0) "\"" + ocamlEscaped(s) + "\"" else s;
		}
		function stringOfServerMode(m:ServerMode) return switch m {
			case SMNone: "None";
			case SMListen(hp): "Listen " + hp;
			case SMConnect(hp): "Connect " + hp;
		}
		function formatPart(p:PartArgs) {
			var raw = toRawArgs(p.args);
			var argsStr = raw.map(quote).join(" ");
			var runtimeStr = p.runtimeArgs.map(quote).join(" ");
			return switch runtimeStr {
				case "": argsStr;
				case _: argsStr + " -- " + runtimeStr;
			}
		}
		var partsStr = [for (i in 0...req.parts.length) "  Part " + (i + 1) + ": " + formatPart(req.parts[i])].join("\n");
		return [
			"server_mode: " + stringOfServerMode(req.serverMode),
			"connect_arg: " + (switch req.connectArg {
				case null: "<none>";
				case s: s;
			}),
			"display_arg: " + (switch req.displayArg {
				case null: "<none>";
				case s: s;
			}),
			"parts:",
			partsStr
		].join("\n");
	}

	// port: OCaml String.escaped (as used by %S), on the UTF-8 bytes of s.
	static function ocamlEscaped(s:String):String {
		var bytes = haxe.io.Bytes.ofString(s);
		var b = new StringBuf();
		for (i in 0...bytes.length) {
			var c = bytes.get(i);
			switch c {
				case '"'.code | '\\'.code:
					b.addChar('\\'.code);
					b.addChar(c);
				case '\n'.code:
					b.add("\\n");
				case '\t'.code:
					b.add("\\t");
				case '\r'.code:
					b.add("\\r");
				case 8:
					b.add("\\b");
				case c if (c >= 32 && c <= 126):
					b.addChar(c);
				case c:
					b.addChar('\\'.code);
					b.addChar(48 + Std.int(c / 100));
					b.addChar(48 + Std.int(c / 10) % 10);
					b.addChar(48 + c % 10);
			}
		}
		return b.toString();
	}
}

@:structInit class PartArgs {
	public var args:Array<ParsedArg>;
	public var runtimeArgs:Array<String>;

	public inline function new(args:Array<ParsedArg>, runtimeArgs:Array<String>) {
		this.args = args;
		this.runtimeArgs = runtimeArgs;
	}

	public inline function clone():PartArgs return new PartArgs(args, runtimeArgs);
}

@:structInit class RequestArgs {
	public var parts:Array<PartArgs>;
	public var serverMode:ServerMode;
	public var connectArg:Null<String>;
	public var displayArg:Null<String>;

	public inline function new(parts:Array<PartArgs>, serverMode:ServerMode, connectArg:Null<String>, displayArg:Null<String>) {
		this.parts = parts;
		this.serverMode = serverMode;
		this.connectArg = connectArg;
		this.displayArg = displayArg;
	}

	public inline function clone():RequestArgs return new RequestArgs(parts, serverMode, connectArg, displayArg);
}
