import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The cache of Mir macros' compiled functions (hxmc/src/hxmc/interp/BundleCache.hx,
// docs/hxmc.md, "Macros on the Mir interpreter"): a program whose expression
// macros call a function of another module (Dep: a loop), a small function
// the Mir inliner copies into its caller (Tiny) and read a define in their
// body (#if), built with Mir macros (-D hxmc.macros=mir, --interp: what the
// program prints) in a cache of its own, the module cache off so the macros
// run every build (HXMC_MIR_CACHE=1). Each build must print what the same
// program prints with Eval's macros, and: a cold build compiles every
// function and finds none, a warm one finds every function; an edit of the
// dependency, of the inlined function and a define change compile again
// what they change (and print the new values); another build of the compiler
// (its copy elsewhere, then its date changed) finds nothing; objects that
// do not read as theirs (truncated, of another function) are compiled again;
// HXMC_MIR_CACHE=0 keeps nothing; with the module cache on (the default) a
// rebuild after an edit of the main module finds every function. In
// bin/hxmc-t/mir-cache (removed when every check passes):
//   HXMC_HAXE=<haxe> HXMC_STD=<hxmc std> bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run MirCacheCheck
class MirCacheCheck {
	static var dir:String;
	static var haxeBin:String;
	static var failures = 0;

	static function check(what:String, ok:Bool) {
		Sys.println((ok ? "ok    " : "FAIL  ") + what);
		if (!ok) failures++;
	}

	static function write(path:String, s:String) {
		var d = haxe.io.Path.directory(path);
		if (d != "" && !FileSystem.exists(d)) mkdirs(d);
		File.saveContent(path, s);
	}

	static final FILES = [
		"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(Gen.value());\n\t\ttrace(Gen.small());\n\t\ttrace(Gen.flag());\n\t}\n}\n",
		"src/Gen.hx" => [
			"import haxe.macro.Expr;",
			"class Gen {",
			"\tpublic static macro function value():Expr return macro $v{Dep.compute(6)};",
			"",
			"\tpublic static macro function small():Expr return macro $v{Tiny.k() * 10};",
			"",
			"\tpublic static macro function flag():Expr {",
			"\t\t#if gate_flag",
			"\t\treturn macro \"on\";",
			"\t\t#else",
			"\t\treturn macro \"off\";",
			"\t\t#end",
			"\t}",
			"}"
		].join("\n") + "\n",
		"src/Dep.hx" => "class Dep {\n\tpublic static function compute(n:Int):Int {\n\t\tvar s = 0;\n\t\tfor (i in 0...n)\n\t\t\ts += i * 3;\n\t\treturn s;\n\t}\n}\n",
		"src/Tiny.hx" => "class Tiny {\n\tpublic static function k():Int return 7;\n}\n"
	];

	// a build of the program (with Mir macros, else Eval's): what it prints,
	// and the functions the cache found and compiled (-1: no line of the cache)
	static function build(?compiler:String, mir = true, ?env:Map<String, Null<String>>, ?args:Array<String>):{out:Null<String>, found:Int, compiled:Int} {
		var e:Map<String, Null<String>> = [
			"HXMC_CACHE" => dir + "/cache",
			"HXMC_MODULE_CACHE" => "0",
			"HXMC_MIR_CACHE" => "1",
			"HXMC_MACRO_STATS" => "1",
			"HXMC_MIR_COLD" => null
		];
		if (env != null)
			for (k => v in env)
				e.set(k, v);
		var cmd = [compiler != null ? compiler : haxeBin, "-cp", "src", "-main", "Main", "--interp"].concat(args != null ? args : []);
		if (mir) cmd = cmd.concat(["-D", "hxmc.macros=mir"]);
		var r = exec(cmd, {cwd: dir + "/p", env: e});
		var found = -1, compiled = -1;
		var re = ~/functions kept \(BundleCache\): (\d+) found, (\d+) compiled/;
		if (re.match(r.err)) {
			found = Std.parseInt(re.matched(1));
			compiled = Std.parseInt(re.matched(2));
		}
		if (r.code != 0) {
			Sys.println(tail(r.out + r.err, 2000));
			return {out: null, found: found, compiled: compiled};
		}
		return {out: r.out, found: found, compiled: compiled};
	}

	// a build with Mir macros against the same with Eval's: the same output
	static function gate(what:String, ?compiler:String, ?env:Map<String, Null<String>>, ?args:Array<String>):{found:Int, compiled:Int} {
		var ref = build(compiler, false, env, args);
		var got = build(compiler, true, env, args);
		check('$what: prints what Eval\'s macros make it print (${got.found} found, ${got.compiled} compiled)', ref.out != null && got.out == ref.out);
		return {found: got.found, compiled: got.compiled};
	}

	static function edit(path:String, from:String, to:String) {
		var p = dir + "/p/" + path;
		var s = File.getContent(p);
		if (s.indexOf(from) < 0) throw 'MirCacheCheck: $from not in $path';
		File.saveContent(p, s.replace(from, to));
	}

	// the objects of the cache (o/<key>-mir.o)
	static function objects():Array<String> {
		var r = [];
		var root = dir + "/cache/modules";
		if (!FileSystem.exists(root)) return r;
		for (t in FileSystem.readDirectory(root)) {
			var o = '$root/$t/o';
			if (FileSystem.exists(o) && FileSystem.isDirectory(o))
				for (f in FileSystem.readDirectory(o))
					if (f.endsWith("-mir.o")) r.push('$o/$f');
		}
		return r;
	}

	static function main() {
		var a = parseArgs(Sys.args(), ["--haxe"]);
		haxeBin = a.has("--haxe") ? a.get("--haxe") : Sys.getEnv("HXMC_HAXE");
		if (haxeBin == null) fail("MirCacheCheck: --haxe <haxe> or HXMC_HAXE");
		haxeBin = FileSystem.fullPath(haxeBin);
		if (Sys.getEnv("HXMC_STD") == null) fail("MirCacheCheck: HXMC_STD (hxmc's std for the macro context)");
		dir = FileSystem.fullPath("bin") + "/hxmc-t/mir-cache";
		rmrf(dir);
		mkdirs(dir);
		for (f => s in FILES)
			write(dir + "/p/" + f, s);

		var cold = gate("cold");
		check('cold: every function compiled, none found (${cold.found} found, ${cold.compiled} compiled)', cold.found == 0 && cold.compiled > 0);
		var warm = gate("warm");
		check('warm: every function found (${warm.found} of ${cold.compiled})', warm.found == cold.compiled && warm.compiled == 0);

		// a dependency edited: what changes compiled again, the rest found
		edit("src/Dep.hx", "i * 3", "i * 5");
		var dep = gate("dependency edited (Dep.compute)");
		check('dependency edited: compiled again (${dep.compiled}), the rest found (${dep.found})', dep.compiled > 0 && dep.found > 0);
		// a function the Mir inliner copies into its caller
		edit("src/Tiny.hx", "return 7", "return 8");
		var tiny = gate("inlined function edited (Tiny.k)");
		check('inlined function edited: compiled again (${tiny.compiled})', tiny.compiled > 0);
		// a define a macro's body reads
		var def = gate("define changed (-D gate_flag)", null, null, ["-D", "gate_flag"]);
		check('define changed: compiled again (${def.compiled})', def.compiled > 0);
		var back = gate("define removed again");
		check('define removed again: every function found (${back.found}, ${back.compiled} compiled)', back.compiled == 0 && back.found > 0);

		// another build of the compiler: its own entries
		var copy = dir + "/bin/haxe" + (Sys.systemName() == "Windows" ? ".exe" : "");
		mkdirs(dir + "/bin");
		File.copy(haxeBin, copy);
		if (Sys.systemName() != "Windows") Sys.command("chmod", ["+x", copy]);
		var other = gate("another compiler (a copy elsewhere)", copy);
		check('another compiler: nothing found (${other.found} found, ${other.compiled} compiled)', other.found == 0 && other.compiled > 0);
		var again = gate("that compiler again", copy);
		check('that compiler again: every function found (${again.found}, ${again.compiled} compiled)', again.compiled == 0 && again.found > 0);
		// (its date changed: another build)
		Sys.sleep(1.1);
		File.saveBytes(copy, File.getBytes(copy));
		var touched = gate("that compiler rewritten (its date)", copy);
		check('that compiler rewritten: nothing found (${touched.found} found)', touched.found == 0 && touched.compiled > 0);

		// objects that do not read as theirs: compiled again
		var objs = objects();
		check('the cache holds objects (${objs.length})', objs.length > 0);
		for (o in objs) {
			var b = File.getBytes(o);
			File.saveBytes(o, b.sub(0, b.length >> 1));
		}
		var trunc = gate("every object truncated", copy);
		check('every object truncated: compiled again, none found (${trunc.found} found, ${trunc.compiled} compiled)', trunc.found == 0 && trunc.compiled > 0);
		// (each object under another one's key, in each compiler's entries)
		var byTool = new Map<String, Array<String>>();
		for (o in objects()) {
			var t = haxe.io.Path.directory(o);
			if (!byTool.exists(t)) byTool.set(t, []);
			byTool.get(t).push(o);
		}
		var rotated = 0;
		for (list in byTool) {
			var bytes = [for (o in list) File.getBytes(o)];
			for (i in 0...list.length)
				File.saveBytes(list[i], bytes[(i + 1) % list.length]);
			rotated += list.length;
		}
		var swapped = gate("objects swapped between keys", copy);
		check('objects swapped: none used (${swapped.found} found, ${swapped.compiled} compiled, $rotated swapped)', rotated > 1 && swapped.found == 0);

		var off = gate("HXMC_MIR_CACHE=0", null, ["HXMC_MIR_CACHE" => "0"]);
		check('HXMC_MIR_CACHE=0: no cache (${off.found})', off.found == -1);

		// the module cache on (the default): an edit of the main module runs its macros again
		var mc:Map<String, Null<String>> = ["HXMC_MODULE_CACHE" => null, "HXMC_MIR_CACHE" => null];
		gate("module cache on, cold", null, mc);
		edit("src/Main.hx", "trace(Gen.flag());", "trace(Gen.flag());\n\t\ttrace(0);");
		var main = gate("module cache on, main module edited", null, mc);
		check('module cache on, main module edited: every function found (${main.found}, ${main.compiled} compiled)', main.compiled == 0 && main.found > 0);

		Sys.println(failures == 0 ? "MirCacheCheck: all ok" : 'MirCacheCheck: $failures failed');
		if (failures == 0) rmrf(dir);
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
