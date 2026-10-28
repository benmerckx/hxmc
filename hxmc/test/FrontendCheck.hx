import Harness.*;
import sys.FileSystem;

using StringTools;

// The frontends' seam (docs/hxmc.md, "Frontends"): a compiler built from
// hxmc's sources with its own main (hxmc/test/frontend/Frontend.hx) adds a
// function to the program after the lowering (hxmc.Main.beforeCodegen) and
// calls it from main; the program it builds prints that function's result,
// then its own line. In bin/hxmc-t/frontend.
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
		rmrf(dir);
		Sys.println("FrontendCheck: ok (the function the frontend added ran)");
	}
}
