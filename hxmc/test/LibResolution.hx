import haxe.io.Path;
import hxmc.libs.Haxelib;
import hxmc.libs.Scope;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// -lib's resolution (hxmc/src/hxmc/libs) against what it reproduces, on
// the same files (`make test LANES=libs`):
//   <haxe> -cp hxmc/test -cp hxmc/src --run LibResolution --haxelib <haxelib> --lix <lix's haxe> [--dir <scratch>] [--summary <file>]
// - Haxelib.run against haxelib itself (the reference's, 4.2.0): `haxelib
//   path` on a repository of versions, dev paths, capitalized names,
//   haxelib.json's fields and dependencies, extraParams.hxml, ndll/, a local
//   repository, the configuration's errors: the exit code, standard output
//   and error, byte for byte;
// - Scope against lix's haxe shim (`haxe --run resolve-args -lib ...`),
//   whose .haxerc's "version" is haxelib's directory (the shim runs that
//   haxelib): each mode, haxe_libraries/*.hxml with interpolations, nested
//   -lib and hxml, haxelib's libraries, ndll, a subdirectory, HAXESHIM_SCOPE,
//   the global scope, the errors (the shim prints the first one's message).
//   The shim passes -lib ndll:<dir> on for its haxelib to answer the
//   compiler; Scope answers it, --neko-lib-path <dir>, as the comparison
//   writes the shim's.
class LibResolution {
	static var haxelib:String;
	static var lix:String;
	static var dir:String;
	static var failures = 0;
	static var cases = 0;
	static final failed:Array<String> = [];

	static function main() {
		var args = Sys.args();
		function opt(name:String, def:Null<String>) {
			var i = args.indexOf(name);
			return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
		}
		haxelib = FileSystem.fullPath(opt("--haxelib", null));
		lix = FileSystem.fullPath(opt("--lix", null));
		dir = opt("--dir", "bin/test/lib-resolution");
		rmrf(dir);
		FileSystem.createDirectory(dir);
		dir = FileSystem.fullPath(dir);
		for (v in ["HAXELIB_PATH", "HAXELIB_DEV_FILTER", "HAXESHIM_SCOPE", "HAXE_ROOT", "HAXESHIM_LIBCACHE", "HAXE_LIBCACHE"])
			Sys.putEnv(v, null);
		haxelibCases();
		scopeCases();
		var result = failures == 0 ? 'LibResolution: $cases/$cases' : 'LibResolution: $failures of $cases failed';
		Sys.println(result);
		// (Harness.summary's: --summary, else GITHUB_STEP_SUMMARY)
		var summary = opt("--summary", Sys.getEnv("GITHUB_STEP_SUMMARY"));
		if (summary != null && summary != "") {
			var o = File.append(summary, false);
			o.writeString("### -lib resolution (haxelib, lix's haxe shim)\n\n```\n" + [result].concat(failed).join("\n") + "\n```\n\n");
			o.close();
		}
		Sys.exit(failures == 0 ? 0 : 1);
	}

	// --- haxelib ---

	static function haxelibCases() {
		var repo = '$dir/root/haxelib';
		write(repo, [
			".repo-version" => "1\n",
			// a library, its dependencies (one at a version), extraParams, ndll
			"alpha/.current" => "1.0.0",
			"alpha/1,0,0/haxelib.json" => '{"name": "alpha", "version": "1.0.0", "classPath": "src", "dependencies": {"gamma": "2.0.0", "Beta": ""}}',
			"alpha/1,0,0/extraParams.hxml" => "# a comment\n\n  -D alpha_extra  \r\n--macro alpha.Macro.init()\n",
			"alpha/1,0,0/ndll/Linux64/alpha.ndll" => "",
			"alpha/1,0,0/src/alpha/A.hx" => "",
			// capitalized (.name), a dev path with %VAR% and a version beside it
			"beta/.name" => "Beta",
			"beta/.current" => "0.1.0",
			"beta/.dev" => "%LIBRES_DEV%/beta/./",
			"beta/0,1,0/haxelib.json" => '{"name": "Beta", "version": "0.1.0"}',
			// two versions
			"gamma/.current" => "1.0.0",
			"gamma/1,0,0/haxelib.json" => '{"name": "gamma", "version": "1.0.0", "classPath": "lib/"}',
			"gamma/2,0,0/haxelib.json" => '{"name": "gamma", "version": "2.0.0", "classPath": "lib/"}',
			// no haxelib.json; an empty extraParams.hxml
			"delta/.current" => "0.3.0",
			"delta/0,3,0/extraParams.hxml" => "\n# nothing\n",
			// invalid JSON
			"epsilon/.current" => "1.0.0",
			"epsilon/1,0,0/haxelib.json" => '{"name": "epsilon",',
			// git, with documentation
			"zeta/.current" => "git",
			"zeta/git/haxelib.json" => '{"name": "zeta", "version": "0.0.1", "documentation": {"defines": "doc/defines.json", "metadata": "doc/meta.json"}}',
			// no .current
			"eta/1,0,0/haxelib.json" => '{"name": "eta"}',
			// a dependency that is not installed
			"theta/.current" => "1.0.0",
			"theta/1,0,0/haxelib.json" => '{"name": "theta", "dependencies": {"missing": ""}}',
			// vcs dependencies, an unusable one, a preview version
			"iota/.current" => "1.0.0-rc.1",
			"iota/1,0,0-rc,1/haxelib.json" => '{"name": "iota", "version": "1.0.0-rc.1", "dependencies": {"zeta": "git:https://example.org/zeta#abc1234", "delta": "not a version"}}',
			// an invalid dependency name
			"kappa/.current" => "1.0.0",
			"kappa/1,0,0/haxelib.json" => '{"name": "kappa", "dependencies": {"ab": ""}}',
			// an invalid name and version: the defaults
			"lambda/.current" => "1.0.0",
			"lambda/1,0,0/haxelib.json" => '{"name": "x", "version": "1.0", "classPath": "a/../b"}',
			// a dotted name
			"my,lib/.current" => "1.0.0",
			"my,lib/1,0,0/haxelib.json" => '{"name": "my.lib", "version": "1.0.0"}',
			// a version that is not installed
			"mu/.current" => "2.0.0",
		]);
		write('$dir/dev', ["beta/haxelib.json" => '{"name": "Beta", "version": "0.2.0", "classPath": "src", "dependencies": {"delta": ""}}']);
		Sys.putEnv("LIBRES_DEV", '$dir/dev');
		Sys.putEnv("HAXELIB_PATH", repo);
		for (libs in [
			["alpha"], ["alpha", "Beta"], ["gamma:1.0.0", "alpha"], ["alpha", "gamma:1.0.0"], ["alpha", "alpha:1.0.0"],
			["ALPHA"], ["beta"], ["beta:0.1.0"], ["delta"], ["epsilon"], ["zeta"], ["iota"], ["eta"], ["theta"], ["kappa"],
			["lambda"], ["my.lib"], ["mu"], ["nonexistent"], ["ab"], ["haxe"], ["foo.zip"], ["bad$name"], ["alpha:notaversion"],
			["alpha:git"], ["alpha:2.0.0"], ["alpha:git:https://example.org/a"], [],
		])
			compareHaxelib('path ${libs.join(" ")}', ["--cwd", dir, "path"].concat(libs));
		Sys.putEnv("HAXELIB_DEV_FILTER", '$dir/other;/nowhere');
		compareHaxelib("path beta, its dev path filtered out", ["--cwd", dir, "path", "beta"]);
		Sys.putEnv("HAXELIB_DEV_FILTER", '$dir/dev');
		compareHaxelib("path beta, its dev path kept by the filter", ["--cwd", dir, "path", "beta"]);
		Sys.putEnv("HAXELIB_DEV_FILTER", null);
		// a local repository (without its format's version: the warning), --global past it
		write('$dir/local/.haxelib', ["omega/.current" => "1.0.0", "omega/1,0,0/haxelib.json" => '{"name": "omega", "version": "1.0.0"}']);
		FileSystem.createDirectory('$dir/local/sub');
		compareHaxelib("a local repository", ["--cwd", '$dir/local/sub', "path", "omega"]);
		compareHaxelib("a local repository, a missing library", ["--cwd", '$dir/local', "path", "alpha"]);
		compareHaxelib("--global", ["--global", "path", "alpha"]);
		compareHaxelib("--cwd that does not exist", ["--cwd", '$dir/nowhere', "path", "alpha"]);
		Sys.putEnv("HAXELIB_PATH", '$dir/nowhere');
		compareHaxelib("HAXELIB_PATH that does not exist", ["--cwd", dir, "path", "alpha"]);
		Sys.putEnv("HAXELIB_PATH", '$dir/dev/beta/haxelib.json');
		compareHaxelib("HAXELIB_PATH a file", ["--cwd", dir, "path", "alpha"]);
		Sys.putEnv("HAXELIB_PATH", null);
	}

	static function compareHaxelib(name:String, args:Array<String>) {
		var expected = run(haxelib, args, dir);
		var actual = Haxelib.run(args, dir + "/", Sys.getEnv);
		check('haxelib $name', 'exit ${expected.code}\n${expected.stdout}\n--- stderr\n${expected.stderr}',
			'exit ${actual.code}\n${actual.stdout}\n--- stderr\n${actual.stderr}');
	}

	// --- lix's scopes ---

	static function scopeCases() {
		var install = Path.directory(haxelib);
		var root = '$dir/root', proj = '$dir/proj';
		Sys.putEnv("HAXESHIM_ROOT", root);
		Sys.putEnv("HAXELIB_PATH", null);
		Sys.putEnv("LIBRES_VAR", "from-env");
		write(proj, [
			"haxe_libraries/a.hxml" => "-cp ${SCOPE_DIR}/a\n-D cwd=${CWD}\n-cp ${__dirname}/x\n-D lc=${HAXE_LIBCACHE}\n-lib b\nnested.hxml\n# @install: lix download\n-D  spaced   value  \n-D env=${LIBRES_VAR}\n",
			"haxe_libraries/b.hxml" => "-cp b/src\n-lib a\n-lib ndll:/n/\n-D b\n",
			"haxe_libraries/h.hxml" => "-lib alpha\n-D h\n-lib b\n",
			"haxe_libraries/v.hxml" => "-lib gamma:1.0.0\n",
			"haxe_libraries/forbidden.hxml" => "-D before\n--next\n-D after\n",
			"haxe_libraries/unknown.hxml" => "-D x=${NOPE}\n-cp ${UNCLOSED\n-D ok\n",
			"haxe_libraries/dir.hxml/.keep" => "",
			"haxe_libraries/missingnested.hxml" => "absent.hxml\n",
			"nested.hxml" => "-D nested\n",
			"sub/nested.hxml" => "-D nested_sub\n",
			"other/.keep" => "",
		]);
		for (mode in ["scoped", "mixed", "haxelib", null]) {
			// (null: the default, scoped)
			File.saveContent('$proj/.haxerc', '{"version": "$install"' + (mode == null ? "" : ', "resolveLibs": "$mode"') + "}");
			for (libs in [["a"], ["b", "a"], ["h"], ["alpha", "b"], ["v"], ["forbidden"], ["unknown"], ["dir"], ["nope"], ["missingnested"],
				["a", "alpha", "gamma:1.0.0"], ["ndll:/x/"], ["gamma:2.0.0"]])
				compareScope('${mode == null ? "default" : mode}: -lib ${libs.join(" -lib ")}', proj, libs);
		}
		File.saveContent('$proj/.haxerc', '{"version": "$install", "resolveLibs": "mixed"}');
		compareScope("a subdirectory", '$proj/sub', ["a", "h"]);
		Sys.putEnv("HAXESHIM_SCOPE", proj);
		compareScope("HAXESHIM_SCOPE", '$dir/root', ["a"]);
		Sys.putEnv("HAXESHIM_SCOPE", null);
		Sys.putEnv("HAXE_LIBCACHE", '$dir/cache');
		compareScope("HAXE_LIBCACHE", proj, ["a"]);
		Sys.putEnv("HAXE_LIBCACHE", null);
		File.saveContent('$proj/.haxerc', '{"version": "$install", "resolveLibs": "nonsense"}');
		compareScope("an invalid resolveLibs", proj, ["a"]);
		File.saveContent('$proj/.haxerc', '{"version": "$install", ');
		compareScope("invalid JSON", proj, ["a"]);
		// the global scope (mixed by default)
		write(root, [".haxerc" => '{"version": "$install"}', "haxe_libraries/g.hxml" => "-D global\n-lib alpha\n"]);
		write('$dir/elsewhere', [".keep" => ""]);
		compareScope("the global scope", '$dir/elsewhere', ["g", "delta"]);
		File.saveContent('$root/.haxerc', '{"version": "$install", "resolveLibs": "scoped"}');
		compareScope("the global scope, scoped", '$dir/elsewhere', ["g", "delta"]);
	}

	static function compareScope(name:String, cwd:String, libs:Array<String>) {
		var args = [];
		for (l in libs) args = args.concat(["-lib", l]);
		var shim = run(lix, ["--run", "resolve-args"].concat(args), cwd);
		var expected = if (shim.code == 0) {
			// (-lib ndll:<dir>: what the shim's haxelib answers the compiler)
			var a = shim.stdout.trim().split("\n");
			var out = [];
			var i = 0;
			while (i < a.length) {
				if (a[i] == "-lib" && i + 1 < a.length && a[i + 1].startsWith("ndll:")) {
					out.push("--neko-lib-path");
					out.push(a[i + 1].substr(5));
					i += 2;
				} else out.push(a[i++]);
			}
			out.join("\n");
		} else "error: " + (shim.stdout + shim.stderr).trim();
		var actual = try {
			var scope = Scope.seek(cwd, Sys.getEnv);
			if (scope == null) throw "no scope";
			var b = scope.build();
			// (as resolve-args)
			b.checkClassPaths = false;
			var out = b.expand(libs, cwd, _ -> null);
			out.concat(b.finish()).join("\n");
		} catch (e:LibraryError) "error: " + e.errors[0].message.trim()
			// (haxe.Json's message past the end: Eval's fastCodeAt is null there, the native runtime's 0)
			.replace("Invalid char null at", "Invalid char 0 at");
		check('lix $name', expected, actual);
	}

	// --- helpers ---

	static function check(name:String, expected:String, actual:String) {
		cases++;
		var ok = expected == actual;
		Sys.println((ok ? "ok   " : "FAIL ") + name);
		if (!ok) {
			failures++;
			failed.push("FAIL " + name);
			Sys.println('  expected:\n${indent(expected)}\n  actual:\n${indent(actual)}');
		}
	}

	static function indent(s:String)
		return s.split("\n").map(l -> "    " + l).join("\n");

	static function run(cmd:String, args:Array<String>, cwd:String):{code:Int, stdout:String, stderr:String} {
		var old = Sys.getCwd();
		Sys.setCwd(cwd);
		var p = new sys.io.Process(cmd, args);
		Sys.setCwd(old);
		var out = p.stdout.readAll().toString(), err = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		return {code: code, stdout: out, stderr: err};
	}

	static function write(base:String, files:Map<String, String>)
		for (name => text in files) {
			FileSystem.createDirectory(Path.directory('$base/$name'));
			File.saveContent('$base/$name', text);
		}

	static function rmrf(path:String) {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (e in FileSystem.readDirectory(path)) rmrf('$path/$e');
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}
}
