import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// hxmc's spans on the other targets (docs/interop.md, "Spans on other
// targets"): kernels compiled by the reference compiler with MkStd's
// hxmc-portable (spans over Bytes), run on Eval (--interp) and as
// JavaScript under node, print what hxmc's build prints (the corpus's golden
// files): SpanInflate's kernel over Bytes (its worker is hxmc's: threads and
// IoBuffers) and SpanPortable. On those targets a failed check throws
// (portable/SpanThrows, its `// expect:` lines), and ofIoBuffer and unsafeOf
// are compile errors naming why (portable/Span*, `// error:`).
//   make portable-check (HAXE_REFERENCE: the reference compiler, default
//   bin/reference/haxe; the outputs in bin/test/portable)
class PortableCheck {
	static final CASES = "hxmc/test/cases";
	static final OWN = "hxmc/test/portable";
	static final OUT = "bin/test/portable";
	// (a golden file's lines a case prints only on hxmc)
	static final HXMC_ONLY = ["SpanInflate" => ": worker,"];
	static var failures = 0;
	static var haxe:String;

	static function check(what:String, ok:Bool, ?detail:String) {
		Sys.println((ok ? "ok    " : "FAIL  ") + what);
		if (!ok) {
			failures++;
			if (detail != null) Sys.println(tail(detail, 1500));
		}
	}

	// trace's lines, compared without the file's directory and the spaces
	// after commas (Eval's trace joins its values with ",", hxmc's with ", ")
	static function normalize(out:String):Array<String> {
		var lines = [];
		for (l in out.replace("\r", "").split("\n")) {
			if (l == "") continue;
			var at = ~/^(?:.*\/)?([A-Za-z0-9_]+\.hx:[0-9]+: )(.*)$/;
			if (at.match(l)) l = at.matched(1) + at.matched(2);
			lines.push(l.replace(", ", ","));
		}
		return lines;
	}

	// a program built by the reference for Eval or JavaScript and run: its output
	static function run(cp:String, main:String, target:String):{ok:Bool, out:String} {
		var args = [haxe, "-cp", cp, "-cp", "bin/hxmc/std/hxmc-portable", "-main", main];
		if (target == "interp") {
			var r = exec(args.concat(["--interp"]), {merge: true});
			return {ok: r.code == 0, out: r.out};
		}
		var js = OUT + "/" + main + ".js";
		var c = exec(args.concat(["--js", js]), {merge: true});
		if (c.code != 0) return {ok: false, out: c.out};
		var r = exec(["node", js], {merge: true});
		return {ok: r.code == 0, out: r.out};
	}

	static function main() {
		haxe = Sys.getEnv("HAXE_REFERENCE");
		if (haxe == null) haxe = "bin/reference/haxe";
		if (!FileSystem.exists(haxe)) fail("PortableCheck: no reference compiler at " + haxe + " (make reference)");
		if (!FileSystem.exists("bin/hxmc/std/hxmc-portable")) fail("PortableCheck: bin/hxmc/std/hxmc-portable is missing (make hxmc)");
		mkdirs(OUT);
		for (name in ["SpanInflate", "SpanPortable"]) {
			var skip = HXMC_ONLY[name];
			var want = [for (l in File.getContent("hxmc/test/expected/" + name + ".txt").replace("\r", "").split("\n"))
				if (l != "" && !l.startsWith("exit ") && (skip == null || l.indexOf(skip) < 0)) l.replace(", ", ",")];
			for (target in ["interp", "js"]) {
				var r = run(CASES, name, target);
				var got = normalize(r.out);
				check('$name on $target: hxmc\'s output', r.ok && got.join("\n") == want.join("\n"),
					r.out + "\n" + lineDiff(want.join("\n"), got.join("\n"), 10).join("\n"));
			}
		}
		for (f in FileSystem.readDirectory(OWN)) {
			if (!f.endsWith(".hx")) continue;
			var name = f.substr(0, f.length - 3);
			var src = File.getContent(OWN + "/" + f).split("\n").map(l -> l.trim());
			var expect = [for (l in src) if (l.startsWith("// expect: ")) l.substr(11)];
			var error = [for (l in src) if (l.startsWith("// error: ")) l.substr(10)];
			for (target in ["interp", "js"]) {
				var r = run(OWN, name, target);
				if (error.length > 0) {
					check('$name on $target: rejected', !r.ok && error.filter(e -> r.out.indexOf(e) < 0).length == 0, r.out);
				} else {
					var got = normalize(r.out);
					check('$name on $target', r.ok && got.join("\n") == normalize(expect.join("\n")).join("\n"), r.out);
				}
			}
		}
		Sys.println(failures == 0 ? "PortableCheck: ok" : 'PortableCheck: $failures failed');
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
