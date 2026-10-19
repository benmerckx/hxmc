package hxmc;

import haxe.io.Path;

// `haxe` with hxmc built in (the npm package): the port's command line, where
// `--custom-target hxmc=<out>` compiles the program to an executable for the
// host (-D hxmc.target=<target> names another). In the package:
//   hxmc/bootstrap/haxe[.exe]        this binary (in place of the launcher; also dist/haxe
//                                    for lix, with dist/std), or
//                                    @hxmc/wasm's haxe.wasm, its WebAssembly build, run by it
//   haxe/upstream/std                the std (HAXE_STD_PATH unless set)
//   hxmc/bootstrap/hxmc-std          hxmc's std (hxmc/std merged by MkStd.hx),
//                                    added last when the arguments (or the hxml
//                                    files they name) select --custom-target hxmc
//   hxmc/bootstrap/rt/<target>       the runtime objects (rt.o, ssl.o, uv.o)
// Elsewhere (the launcher runs it from its cache) HAXE_STD_PATH, HXMC_STD and
// HXMC_RT_DIR name them. The WebAssembly build learns the host from HXMC_HOST.
class HaxeMain {
	static function main() {
		Sys.exit(run(Sys.args()));
	}

	public static function run(args:Array<String>):Int {
		Defines.install();
		if (args[0] == "--dev") return dev(args.slice(1));
		var failed = null;
		// (through links to the binary, as npm's node_modules/.bin/haxe)
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		// (hxmc/bootstrap/haxe, or dist/haxe: the installation lix uses)
		var boot = Path.directory(exe);
		if (!sys.FileSystem.exists(boot + "/launcher.mjs") && sys.FileSystem.exists(boot + "/../hxmc/bootstrap/launcher.mjs"))
			boot = Path.directory(boot) + "/hxmc/bootstrap";
		if (sys.FileSystem.exists(boot + "/launcher.mjs")) {
			var pkg = Path.directory(Path.directory(boot));
			if (Sys.getEnv("HXMC_RT_DIR") == null)
				Options.rtDirOverride = boot + "/rt/";
			// the port looks for the std next to the binary as upstream does
			// (<bin>/lib/haxe/std, ...): this layout's through HAXE_STD_PATH
			if (Sys.getEnv("HAXE_STD_PATH") == null)
				Sys.putEnv("HAXE_STD_PATH", pkg + "/haxe/upstream/std");
			if (Sys.getEnv("HXMC_STD") == null)
				Sys.putEnv("HXMC_STD", boot + "/hxmc-std");
		}
		// hxmc's std, given last (a custom target gets no std of its own)
		var hxmcStd = Sys.getEnv("HXMC_STD");
		if (hxmcStd != null && selectsHxmc(args, 0)) args = args.concat(["-cp", hxmcStd]);
		var host = hostTarget();
		// (the port calls the hook with --no-output too: e.g. writing HXB only)
		var noOutput = args.contains("--no-output");
		// a compilation server keeps what it can between builds (as `hxmc
		// --server`): the lowered bodies of the fields it kept (LowerCache) and
		// the compiled modules in memory
		for (a in ["--wait", "--server-listen", "--server-connect"])
			if (args.contains(a)) Driver.resident = true;
		compiler.Compiler.generateHook = function(com) {
			if (noOutput) return;
			switch com.platform {
				case CustomTarget("hxmc"):
				case _: return;
			}
			try {
				if (!core.Define.rawDefined(com.defines, "hxmc.target")) {
					if (host == null) throw "hxmc: the host is unknown (HXMC_HOST): name the target with -D hxmc.target=<target>";
					core.Define.rawDefineValue(com.defines, "hxmc.target", host);
				}
				// (hxmc dev: the program typed, its code next; the page may load again meanwhile, dev.mjs)
				if (Driver.resident && devProgress) {
					Sys.println("hxmc dev: generating");
					Sys.stdout().flush();
				}
				@:privateAccess Main.generate(com, com.file);
			} catch (e:Dynamic) {
				// (a compilation server's client gets it as an error: hxmc dev)
				if (Driver.resident) com.error("hxmc: " + Std.string(e), core.Globals.nullPos) else failed = Std.string(e);
			}
		}
		// -lib from node_modules before lix and haxelib (NodeLibs.hx)
		compiler.HighLevel.libraryHook = NodeLibs.resolve;
		ModuleCache.install();
		hxmc.ir.CInterop.install();
		#if hxmc.jit
		// native macros (hxmc/src/hxmc/macro): a child compiling macro code for
		// its parent (Guest), or the engine of -D hxmc.macros=native|verify
		var guest = Sys.getEnv("HXMC_MACRO_GUEST");
		var engine:Null<hxmc.macro.NativeEngine> = null;
		if (guest != null && guest != "") hxmc.macro.Guest.install(guest) else macros.MacroEngine.engine = engine = new hxmc.macro.NativeEngine();
		var code = haxe.Main.run(args);
		if (engine != null) engine.report();
		#else
		var code = haxe.Main.run(args);
		#end
		ModuleCache.finish(failed == null ? code : 1);
		if (failed != null) {
			Sys.stderr().writeString("hxmc: " + failed + "\n");
			return 1;
		}
		return code;
	}

	static var devProgress = Sys.getEnv("HXMC_DEV_PROGRESS") == "1";

	// `haxe --dev <arguments>`, `hxmc dev <arguments>`: the dev loop (docs/dev.md),
	// node running dev.mjs (beside this binary in the npm package, HXMC_DEV_SCRIPT
	// from the launcher, packages/cli in the repository), which keeps this
	// compiler resident as a compilation server
	public static function dev(args:Array<String>):Int {
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		var dir = Path.directory(exe);
		var script = Sys.getEnv("HXMC_DEV_SCRIPT");
		for (c in [dir + "/dev.mjs", dir + "/../hxmc/bootstrap/dev.mjs", dir + "/../../packages/cli/hxmc/bootstrap/dev.mjs"])
			if (script == null && sys.FileSystem.exists(c)) script = c;
		if (script == null) {
			Sys.stderr().writeString("hxmc dev: dev.mjs is not beside the compiler (" + dir + ")\n");
			return 1;
		}
		var node = Sys.getEnv("HXMC_NODE");
		return Sys.command(node == null || node == "" ? "node" : node, [script, exe].concat(args));
	}

	// whether the arguments, or the hxml files they name, contain --custom-target hxmc
	static function selectsHxmc(args:Array<String>, depth:Int):Bool {
		for (i in 0...args.length) {
			var a = args[i];
			if ((a == "--custom-target" || a == "-custom-target") && i + 1 < args.length && (args[i + 1] == "hxmc" || StringTools.startsWith(args[i + 1], "hxmc=")))
				return true;
			if (StringTools.endsWith(a, ".hxml") && depth < 8 && sys.FileSystem.exists(a)) {
				var words = [];
				for (line in sys.io.File.getContent(a).split("\n")) {
					line = StringTools.trim(line);
					if (line == "" || StringTools.startsWith(line, "#")) continue;
					var sp = line.indexOf(" ");
					if (sp < 0) words.push(line) else {
						words.push(line.substr(0, sp));
						words.push(StringTools.trim(line.substr(sp + 1)));
					}
				}
				if (selectsHxmc(words, depth + 1)) return true;
			}
		}
		return false;
	}

	// the target this binary runs on
	static function hostTarget():Null<String> {
		var env = Sys.getEnv("HXMC_HOST");
		if (env != null) return env;
		var t = haxe.macro.Compiler.getDefine("hxmc.target");
		return t == null || t == "1" ? "linux-x86_64" : t == "wasm32-wasi" ? null : t;
	}
}
