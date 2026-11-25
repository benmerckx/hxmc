import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// hxmc's JavaScript generator (hxmc/src/hxmc/es, docs/js.md): each case of
// hxmc/test/jsgen/cases, built by the port's generator (where js.Bundle.split
// runs its initializer itself) and by hxmc's in each mode, run under node,
// prints the same; a case that splits makes a file per split.
//   make jsgen-check (the compiler: bin/jsgen/haxe, make jsgen; the outputs
//   in bin/test/jsgen; CASES="Basic Features" for some)
class JsGenCheck {
	static final CASES = "hxmc/test/jsgen/cases";
	static final OUT = "bin/test/jsgen";
	static var failures = 0;
	static var haxe:String;

	static function check(what:String, ok:Bool, ?detail:String) {
		Sys.println((ok ? "ok    " : "FAIL  ") + what);
		if (!ok) {
			failures++;
			if (detail != null) Sys.println(tail(detail, 3000));
		}
	}

	static function build(main:String, dir:String, extra:Array<String>):{ok:Bool, out:String} {
		rmrf(dir);
		FileSystem.createDirectory(dir);
		var js = dir + "/main.js";
		var c = exec([haxe, "-cp", CASES, "-cp", "hxmc/portable", "-main", main, "--js", js].concat(extra), {merge: true});
		if (c.code != 0) return {ok: false, out: c.out};
		// (ES modules for node: hxmc.js=es-modules)
		if (extra.contains("hxmc.js=es-modules")) File.saveContent(dir + "/package.json", "{\"type\": \"module\"}\n");
		// (-D hxmc.check.wrapped: run inside a function a module calls later, as a page that wraps the
		// program does: no current script, no __filename; the split files from the stack)
		if (extra.contains("hxmc.check.wrapped")) {
			var wrapped = dir + "/main-wrapped.mjs";
			File.saveContent(wrapped, "setTimeout(() => {\n" + File.getContent(js) + "\n}, 0);\n");
			js = wrapped;
		}
		var r = exec(["node", js], {merge: true});
		return {ok: r.code == 0, out: r.out};
	}

	static function rmrf(path:String) {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (n in FileSystem.readDirectory(path)) rmrf(path + "/" + n);
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}

	// the names of the splits of a case: a file each
	static function splitsIn(src:String):Int {
		var names = new Map<String, Bool>(), re = ~/js\.Bundle\.split\("([^"]*)"/g;
		re.map(src, r -> {
			names.set(r.matched(1), true);
			return "";
		});
		return Lambda.count(names);
	}

	// the sources of a case's package (`cases/lazies` of Lazies), whose splits are the case's too
	static function caseModules(name:String):String {
		var dir = '$CASES/${name.toLowerCase()}';
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return "";
		var b = new StringBuf();
		for (f in FileSystem.readDirectory(dir)) if (StringTools.endsWith(f, ".hx")) b.add(File.getContent('$dir/$f'));
		return b.toString();
	}

	static function main() {
		haxe = Sys.getEnv("HXMC_JSGEN");
		if (haxe == null || haxe == "") haxe = "bin/jsgen/haxe";
		if (Sys.getEnv("HAXE_STD_PATH") == null) Sys.putEnv("HAXE_STD_PATH", FileSystem.fullPath("haxe/upstream/std"));
		var only = Sys.args();
		var names = [for (f in FileSystem.readDirectory(CASES)) if (f.endsWith(".hx")) f.substr(0, f.length - 3)];
		names.sort(Reflect.compare);
		for (name in names) {
			if (only.length > 0 && !only.contains(name)) continue;
			var src = File.getContent('$CASES/$name.hx');
			var plain = build(name, '$OUT/$name/plain', []);
			check('$name: plain', plain.ok, plain.out);
			if (!plain.ok) continue;
			// (no `require` in an ES module: the wrapped run is one)
			var wrappable = src.indexOf("@:jsRequire") < 0;
			for (v in [{tag: "es", args: ["-D", "hxmc.js=es"]}, {tag: "es-es5", args: ["-D", "hxmc.js=es", "-D", "js-es=5"]},
				{tag: "es-min", args: ["-D", "hxmc.js=es", "-D", "hxmc.js.minify"]},
				{tag: "es-fields", args: ["-D", "hxmc.js=es", "-D", "hxmc.js.minify", "-D", "hxmc.js.minify.fields"]},
				{tag: "es-aside", args: ["-D", "hxmc.js=es", "-D", "hxmc.js.minify=aside", "-D", "hxmc.js.hash-length=5"]},
				{tag: "es-debug", args: ["-D", "hxmc.js=es", "--debug"]},
				{tag: "es-fields-debug", args: ["-D", "hxmc.js=es", "-D", "hxmc.js.minify", "-D", "hxmc.js.minify.fields", "--debug"]},
				{tag: "es-wrapped", args: ["-D", "hxmc.js=es", "-D", "hxmc.check.wrapped"]},
				{tag: "es-modules", args: ["-D", "hxmc.js=es-modules"]}, {tag: "es-modules-debug", args: ["-D", "hxmc.js=es-modules", "--debug"]},
				{tag: "es-full", args: ["-D", "hxmc.js=es", "--dce", "full"]}, {tag: "es-modules-full", args: ["-D", "hxmc.js=es-modules", "--dce", "full"]}
			]) {
				if (v.tag == "es-wrapped" && !wrappable) continue;
				var dir = '$OUT/$name/${v.tag}';
				var r = build(name, dir, v.args);
				check('$name: ${v.tag} runs', r.ok, r.out);
				if (!r.ok) continue;
				check('$name: ${v.tag} prints as plain', r.out == plain.out, "plain:\n" + plain.out + "\n" + v.tag + ":\n" + r.out);
				var files = [for (f in FileSystem.readDirectory(dir)) if (~/_[0-9a-f]{8}\.js$/.match(f) || (v.tag == "es-aside" && ~/_[0-9a-f]{5}\.js$/.match(f))) f];
				// (es-modules: a split imports the modules it needs, no file of its own)
				var want = v.tag.startsWith("es-modules") ? 0 : splitsIn(src + caseModules(name));
				check('$name: ${v.tag} has ${want} split files', files.length == want, files.join(" "));
				// (what the case says its output has: `// output has: <text>`, in the plain es output's main.js)
				if (v.tag == "es") {
					var re = ~/^\/\/ output has: (.*)$/gm, pos = 0, code = File.getContent(dir + "/main.js");
					while (re.matchSub(src, pos)) {
						check('$name: ${v.tag} has `' + re.matched(1) + "`", code.indexOf(re.matched(1)) >= 0);
						var m = re.matchedPos();
						pos = m.pos + m.len;
					}
				}
				if (v.tag == "es-aside") {
					// (beside them the minified program, main.min.js, with split files of its own)
					var mins = [for (f in FileSystem.readDirectory(dir)) if (~/_[0-9a-f]{5}\.min\.js$/.match(f)) f];
					check('$name: ${v.tag} has ${want} minified split files', mins.length == want, mins.join(" "));
					var m = exec(["node", dir + "/main.min.js"], {merge: true});
					check('$name: ${v.tag} main.min.js prints as plain', m.code == 0 && m.out == plain.out, m.out);
				}
				if (v.tag.endsWith("-debug")) {
					check('$name: ${v.tag} maps main.js', FileSystem.exists(dir + "/main.js.map") && File.getContent(dir + "/main.js").indexOf("//# sourceMappingURL=main.js.map") >= 0);
					var maps = [for (f in files) if (FileSystem.exists(dir + "/" + f + ".map") && File.getContent(dir + "/" + f).indexOf("//# sourceMappingURL=" + f + ".map") >= 0) f];
					check('$name: ${v.tag} maps every split file', maps.length == files.length, maps.join(" "));
				}
			}
		}
		Sys.println(failures == 0 ? "all passed" : '$failures failed');
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
