import Harness.*;
import sys.FileSystem;

using StringTools;

// The checks of single parts of the tool, each a line with its result:
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Units
// - root facts: Roots and MirCompact on hand-made functions
//   (RootFactsCheck, MirCompactCheck: a program built by the tool, run with
//   RT_VERIFY=1);
// - the module cache's store: tool directories, the trim, packs, the cap, an
//   unwritable cache (CacheCheck);
// - where the tool finds the runtime objects in npm's layout (RtSearchCheck;
//   not on Windows);
// - the frontends' seam (docs/hxmc.md, "Frontends"): a compiler built from
//   hxmc's sources with its own main (hxmc/test/frontend/Frontend.hx) adds
//   a function after the lowering (hxmc.Main.beforeCodegen) and calls it
//   from main; the program it builds prints that function's result, then its
//   own line.
// Exits 1 if one failed.
class Units {
	static function rootFacts():Int {
		var dir = "bin/hxmc-t/root-facts";
		mkdirs(dir);
		var out = dir + "/m" + (windows ? ".exe" : "");
		var r = exec(["bin/hxmc/hxmc", out, "-cp", "haxe/src", "-cp", "hxmc/src", "-cp", "hxmc/test", "-D", "disable-parallelism",
			"-D", "hih_no_generators", "-main", "RootFactsCheck", "-cp", "bin/hxmc/std", "--custom-target", "hxmc"], {merge: true});
		if (r.code == 0) r = exec([FileSystem.fullPath(out)], {merge: true, env: ["RT_VERIFY" => "1", "RT_MINOR_KB" => "64"]});
		Sys.println(r.out.trim());
		return r.code;
	}

	static function frontend():Int {
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
		if (r.code != 0 || !FileSystem.exists(exe)) return say("frontend: its build failed\n" + tail(r.out, 2000));
		var app = dir + "/app" + (windows ? ".exe" : "");
		r = exec([exe, "-cp", "hxmc/test/frontend/app", "-main", "Main", "--custom-target", "hxmc=" + app], {env: env, merge: true});
		if (r.code != 0 || !FileSystem.exists(app)) return say("frontend: its build of the program failed\n" + tail(r.out, 2000));
		r = exec([app], {merge: true});
		if (r.code != 0 || r.out.replace("\r", "") != "answer 42\nanswer 1\n") return say("frontend: the program printed\n" + r.out);
		rmrf(dir);
		Sys.println("frontend: ok (the function the frontend added ran)");
		return 0;
	}

	static function say(msg:String):Int {
		Sys.println(msg);
		return 1;
	}

	static function main() {
		var units:Array<{name:String, run:() -> Int}> = [
			{name: "root facts", run: rootFacts},
			{name: "module cache store", run: () -> CacheCheck.run()},
			{name: "frontend seam", run: frontend}
		];
		if (!windows) units.insert(2, {name: "runtime-object search", run: () -> RtSearchCheck.run()});
		var failed = [for (u in units) if (u.run() != 0) u.name];
		if (failed.length > 0) fail("Units: failed: " + failed.join(", "));
		Sys.println("Units: all passed");
	}
}
