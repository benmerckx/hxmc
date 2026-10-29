import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The frontends' seam (docs/hxmc.md, "Frontends"): a compiler built from
// hxmc's sources with its own main (hxmc/test/frontend/Frontend.hx) adds a
// function to the program after the lowering (hxmc.Main.beforeCodegen) and
// calls it from main; the program it builds prints that function's result,
// then its own line. The frontend also types markup literals
// (typing.Typer.markupHook): the program of hxmc/test/frontend/markup prints
// them as it types them, a display request in one gets the type of what it
// becomes, and hxmc's own compiler (no hook) gives upstream's error at each.
// In bin/hxmc-t/frontend.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run FrontendCheck
class FrontendCheck {
	static function main() {
		var dir = FileSystem.fullPath("bin") + "/hxmc-t/frontend";
		rmrf(dir);
		mkdirs(dir);
		var env:Map<String, Null<String>> = [
			"HAXE_STD_PATH" => root + "/haxe/upstream/std",
			"HXMC_RT_DIR" => root + "/bin/hxmc/rt",
			"HXMC_STD" => root + "/bin/hxmc/std",
		];
		var exe = dir + "/frontend" + (windows ? ".exe" : "");
		var r = exec(["bin/hxmc/hxmc", exe, "-cp", "haxe/src", "-cp", "hxmc/src", "-cp", "hxmc/test/frontend", "-main", "Frontend", "-D", "disable-parallelism",
			"-D", "hih_no_generators", "-cp", "bin/hxmc/std", "--custom-target", "hxmc"], {env: env, merge: true});
		if (r.code != 0 || !FileSystem.exists(exe)) fail("FrontendCheck: the frontend's build failed\n" + tail(r.out, 2000));
		var app = dir + "/app" + (windows ? ".exe" : "");
		r = exec([exe, "-cp", "hxmc/test/frontend/app", "-main", "Main", "--custom-target", "hxmc=" + app], {env: env, merge: true});
		if (r.code != 0 || !FileSystem.exists(app)) fail("FrontendCheck: the frontend's build of the program failed\n" + tail(r.out, 2000));
		r = exec([app], {merge: true});
		if (r.code != 0 || r.out.replace("\r", "") != "answer 42\nanswer 1\n") fail("FrontendCheck: the program printed\n" + r.out);
		var markup = dir + "/markup" + (windows ? ".exe" : "");
		r = exec([exe, "-cp", "hxmc/test/frontend/markup", "-main", "Main", "--custom-target", "hxmc=" + markup], {env: env, merge: true});
		if (r.code != 0 || !FileSystem.exists(markup)) fail("FrontendCheck: the frontend's build of the markup program failed\n" + tail(r.out, 2000));
		r = exec([markup], {merge: true});
		if (r.code != 0 || r.out.replace("\r", "") != "markup <p>hello</p>\n<p>world</p> (String)\n11\n")
			fail("FrontendCheck: the markup program printed\n" + r.out);
		// (display: a hover in the Int literal, the file's diagnostics)
		var file = "hxmc/test/frontend/markup/Main.hx";
		var offset = File.getContent(file).indexOf("<b>four") + 3;
		function display(compiler:String, rpc:String, ?offset:Int):String {
			var params = '"file":"' + file + '"' + (offset == null ? "" : ',"offset":' + offset);
			return exec([compiler, "-cp", "hxmc/test/frontend/markup", "-main", "Main", "--no-output", "--display",
				'{"method":"' + rpc + '","id":1,"params":{' + params + "}}"], {env: env, merge: true}).out;
		}
		var out = display(exe, "display/hover", offset);
		if (out.indexOf('"item":{"kind":"Literal","args":{"name":"11"},"type":{"kind":"TAbstract","args":{"path":{"pack":[],"moduleName":"StdTypes","typeName":"Int"') < 0)
			fail("FrontendCheck: the hover in a markup literal gave\n" + out);
		out = display(exe, "display/diagnostics");
		if (out.indexOf('{"result":[],') < 0) fail("FrontendCheck: the markup program's diagnostics are\n" + out);
		out = display("bin/hxmc/hxmc", "display/hover", offset);
		if (out.indexOf("Markup literals must be processed by a macro") < 0) fail("FrontendCheck: without the hook, the hover gave\n" + out);
		r = exec(["bin/hxmc/hxmc", "-cp", "hxmc/test/frontend/markup", "-main", "Main", "-D", "message.reporting=classic", "--no-output"], {env: env, merge: true});
		var expected = [for (at in ["6: characters 9-21", "25: characters 10-22", "12: characters 15-26"])
			file + ":" + at + " : Markup literals must be processed by a macro\n"].join("");
		if (r.code != 1 || r.out.replace("\r", "").replace("\\", "/") != expected) fail("FrontendCheck: without the hook, the markup program gave\n" + r.out);
		rmrf(dir);
		Sys.println("FrontendCheck: ok (the function the frontend added ran, its markup literals were typed)");
	}
}
