package hxmc;

import haxe.io.Path;

// `haxe` with hxmc built in (the npm package @hxmc/cli, docs/using.md): the
// port's command line, where `--custom-target hxmc=<out>` compiles the
// program to an executable for the host (-D hxmc.target=<target> names
// another). In the package:
//   hxmc/bootstrap/haxe[.exe]        this binary (in place of the launcher; also dist/haxe
//                                    for lix, with dist/std)
//   haxe/upstream/std                the std (HAXE_STD_PATH unless set)
//   hxmc/bootstrap/hxmc-std          hxmc's std (hxmc/std merged by MkStd.hx),
//                                    added last when the arguments (or the hxml
//                                    files they name) select --custom-target hxmc
// The launcher (hxmc/bootstrap/launcher.mjs) runs it with HXMC_STD and
// HXMC_RT_DIR, the directories of the runtime objects (the platform
// packages, @hxmc/<os>-<cpu>: Options.rtDir). Run without the launcher (in
// its place), a build for the hxmc target goes through the launcher, which
// finds them. The WebAssembly build learns the host from HXMC_HOST.
class HaxeMain {
	static function main() {
		Sys.exit(run(Sys.args()));
	}

	public static function run(args:Array<String>):Int {
		// (through links to the binary, as npm's node_modules/.bin/haxe)
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		// (hxmc/bootstrap/haxe, or dist/haxe: the installation lix uses)
		var boot = Path.directory(exe);
		if (!sys.FileSystem.exists(boot + "/launcher.mjs") && sys.FileSystem.exists(boot + "/../hxmc/bootstrap/launcher.mjs"))
			boot = Path.directory(boot) + "/hxmc/bootstrap";
		if (sys.FileSystem.exists(boot + "/launcher.mjs")) {
			// (not run by the launcher, which always sets HXMC_RT_DIR: a build
			// for hxmc needs the runtime objects it finds)
			if (Sys.getEnv("HXMC_RT_DIR") == null && selectsHxmc(args, 0)) {
				var node = Sys.getEnv("HXMC_NODE");
				return Sys.command(node == null || node == "" ? "node" : node, [boot + "/haxe.mjs"].concat(args));
			}
			// the port looks for the std next to the binary as upstream does
			// (<bin>/lib/haxe/std, ...): this layout's through HAXE_STD_PATH
			if (Sys.getEnv("HAXE_STD_PATH") == null)
				Sys.putEnv("HAXE_STD_PATH", Path.directory(Path.directory(boot)) + "/haxe/upstream/std");
			if (Sys.getEnv("HXMC_STD") == null)
				Sys.putEnv("HXMC_STD", boot + "/hxmc-std");
		}
		Defines.install();
		if (args[0] == "--dev") return dev(args.slice(1));
		// the engines: -D hxmc.macros=mir|eval for macros, -D hxmc.run=mir|eval
		// for --interp and --run (both Eval by default)
		var macroEngine = "eval", runEngine = "eval";
		try {
			macroEngine = engine(args, MACROS, "the macro engine");
			runEngine = engine(args, RUN, "the engine of --interp and --run");
		} catch (e:String) {
			Sys.stderr().writeString("hxmc: " + e + "\n");
			return 1;
		}
		if (runEngine == "eval") args = without(args, RUN);
		// (a native compiler loads code for the Mir interpreter: it is a Mir host,
		// Mem.mirHost, because it has these classes; the WebAssembly one has
		// nothing to link such code into, and does not type them: its
		// Type.createInstance would keep them)
		#if (hxmc.target != "wasm32-wasi" && !hxmc.wasm_gc)
		// (-D hxmc.run=mir: --interp and --run on the Mir interpreter, interp.MirRun)
		if (runEngine == "mir") args = hxmc.interp.MirRun.rewrite(args);
		#else
		if (macroEngine == "mir" || runEngine == "mir") {
			Sys.stderr().writeString("hxmc: the Mir interpreter (-D " + (macroEngine == "mir" ? MACROS : RUN) + "=mir) is not in this compiler (WebAssembly)\n");
			return 1;
		}
		#end
		var failed = null;
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
				#if (hxmc.target != "wasm32-wasi" && !hxmc.wasm_gc)
				if (hxmc.interp.MirRun.selected(com)) {
					hxmc.interp.MirRun.run(com);
					return;
				}
				#end
				@:privateAccess Main.generate(com, com.file);
			} catch (e:Dynamic) {
				// (a compilation server's client gets it as an error: hxmc dev)
				if (Driver.resident) com.error("hxmc: " + Std.string(e), core.Globals.nullPos) else failed = Std.string(e);
			}
		}
		// -lib: lix's scopes, node_modules, haxelib without a process (libs/Libraries.hx)
		hxmc.libs.Libraries.install(args[0] != "--cwd");
		ModuleCache.install();
		hxmc.ir.CInterop.install();
		hxmc.TargetFlags.install();
		// (not among the compilation's defines: its defines are the reference's,
		// Compiler.getDefine, hxcpp's Options.txt, the modules' signatures)
		args = without(args, MACROS);
		#if (hxmc.target != "wasm32-wasi" && !hxmc.wasm_gc)
		// (the runtime's functions macro code calls: in the executable)
		hxmc.macro.MirHost.runtime();
		// (-D hxmc.macros=mir: macros on the Mir interpreter, the macro context typed for hxmc)
		if (macroEngine == "mir") hxmc.interp.MirMacros.install(hxmcStd);
		var code = haxe.Main.run(args);
		if (macroEngine == "mir") @:privateAccess hxmc.interp.MirMacros.self.report();
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

	// the engines' defines (HaxeMain.run)
	public static inline var MACROS = "hxmc.macros";
	public static inline var RUN = "hxmc.run";

	// a define's name as the defines keep it (an underscore for a dash)
	public static function defineName(d:String):String {
		var eq = d.indexOf("=");
		return StringTools.replace(eq < 0 ? d : d.substr(0, eq), "-", "_");
	}

	// the engine -D <name>=mir|eval selects (the last one; eval when absent)
	static function engine(args:Array<String>, name:String, what:String):String {
		var v = "eval";
		for (i in 0...args.length - 1)
			if ((args[i] == "-D" || args[i] == "--define") && defineName(args[i + 1]) == name) {
				var d = args[i + 1], eq = d.indexOf("=");
				v = eq < 0 ? "" : d.substr(eq + 1);
			}
		if (v != "mir" && v != "eval") throw '-D $name=$v: unknown value for $what (mir: the Mir interpreter; eval, the default: Eval)';
		return v;
	}

	// the command line without -D <name>=...
	static function without(args:Array<String>, name:String):Array<String> {
		var out = [];
		var i = 0;
		while (i < args.length) {
			if ((args[i] == "-D" || args[i] == "--define") && i + 1 < args.length && defineName(args[i + 1]) == name) {
				i += 2;
				continue;
			}
			out.push(args[i]);
			i++;
		}
		return out;
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
