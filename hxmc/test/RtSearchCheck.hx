import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Where the tool finds a target's runtime objects (hxmc/src/hxmc/Options.hx,
// rtSearch) in npm's layout, without the launcher: bin/hxmc-t/rtsearch/
// node_modules/@hxmc/<host package>/ holds the tool (as the platform
// package's `haxe`, a hard link) and its targets' <target>/ (links to
// bin/hxmc/rt's), @hxmc/win32-x64/ another machine's platform package
// beside it. With HXMC_RT_DIR unset a build for the host finds its objects
// beside the tool, and one for windows-x86_64 in the package beside it (not
// in one of another version); HXMC_RT_DIR adds to the search (a directory
// without the host's objects, one with windows-x86_64's); with none of them
// the error lists every directory searched. Unix.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run RtSearchCheck
class RtSearchCheck {
	static var failures = 0;
	static var dir:String;
	static var exe:String;

	static function check(what:String, ok:Bool, ?detail:String) {
		Sys.println((ok ? "ok    " : "FAIL  ") + what);
		if (!ok) {
			failures++;
			if (detail != null) Sys.println(tail(detail, 1200));
		}
	}

	// a build of the program for target by the platform package's tool with
	// HXMC_RT_DIR (null: unset)
	static function build(target:String, out:String, rtDir:Null<String>) {
		if (FileSystem.exists(out)) FileSystem.deleteFile(out);
		return exec([exe, out, "-cp", dir + "/src", "-main", "Main", "-cp", FileSystem.fullPath("bin/hxmc/std"), "--custom-target", "hxmc", "-D", "hxmc.target=" + target], {
			env: ["HXMC_RT_DIR" => rtDir, "HXMC_RT_OBJ" => null, "HXMC_CACHE" => dir + "/cache"],
			merge: true
		});
	}

	static function pkg(name:String, version:String, targets:Array<String>) {
		var p = dir + "/node_modules/@hxmc/" + name;
		mkdirs(p);
		File.saveContent(p + "/package.json", '{"name": "@hxmc/$name", "version": "$version"}\n');
		for (t in targets)
			if (exec(["ln", "-s", FileSystem.fullPath("bin/hxmc/rt/" + t), p + "/" + t]).code != 0) fail("RtSearchCheck: cannot link " + t);
		return p;
	}

	static function main() {
		var uname = exec(["uname", "-sm"]).out.trim();
		var host = switch uname {
			case "Linux x86_64": {target: "linux-x86_64", pkg: "linux-x64"};
			case "Linux aarch64": {target: "linux-arm64", pkg: "linux-arm64"};
			case "Darwin x86_64": {target: "macos-x86_64", pkg: "darwin-x64"};
			case "Darwin arm64": {target: "macos-arm64", pkg: "darwin-arm64"};
			case _: fail("RtSearchCheck: no platform package for " + uname);
		}
		for (t in [host.target, "windows-x86_64"])
			if (!FileSystem.exists("bin/hxmc/rt/" + t + "/rt.o")) fail("RtSearchCheck: bin/hxmc/rt/" + t + " is missing (make rt)");
		dir = FileSystem.fullPath("bin") + "/hxmc-t/rtsearch";
		rmrf(dir);
		mkdirs(dir + "/src");
		File.saveContent(dir + "/src/Main.hx", 'class Main { static function main() { Sys.println("hi"); } }\n');
		var own = pkg(host.pkg, "1.0.0", [host.target]);
		exe = own + "/haxe";
		if (exec(["ln", FileSystem.fullPath("bin/hxmc/hxmc"), exe]).code != 0) File.copy("bin/hxmc/hxmc", exe);
		var app = dir + "/app", cross = dir + "/cross.exe";

		var r = build(host.target, app, null);
		check("the host's objects beside the tool, HXMC_RT_DIR unset", r.code == 0 && exec([app]).out == "hi\n", r.out);

		mkdirs(dir + "/empty");
		r = build(host.target, app, dir + "/empty");
		check("HXMC_RT_DIR without them adds to the search", r.code == 0 && exec([app]).out == "hi\n", r.out);

		r = build("windows-x86_64", cross, null);
		var msg = r.out;
		check("no win32-x64 package: the error lists every directory searched", r.code != 0 && !FileSystem.exists(cross)
			&& msg.contains("@hxmc/win32-x64") && msg.contains(own + "/windows-x86_64/rt.o") && msg.contains(own + "/rt/windows-x86_64/rt.o"), msg);

		r = build("windows-x86_64", cross, dir + "/empty");
		check("the error lists HXMC_RT_DIR's directories first", r.code != 0 && r.out.contains("searched: " + dir + "/empty/windows-x86_64/rt.o, "), r.out);

		var other = pkg("win32-x64", "0.9.0", ["windows-x86_64"]);
		r = build("windows-x86_64", cross, null);
		check("not the platform package beside it of another version", r.code != 0 && !FileSystem.exists(cross), r.out);

		File.saveContent(other + "/package.json", '{"name": "@hxmc/win32-x64", "version": "1.0.0"}\n');
		r = build("windows-x86_64", cross, null);
		check("windows-x86_64's objects in the platform package beside it", r.code == 0 && FileSystem.exists(cross), r.out);
		rmrf(other);

		// (a cross build naming another machine's objects keeps the host's)
		var extracted = dir + "/win32-x64";
		mkdirs(extracted);
		exec(["ln", "-s", FileSystem.fullPath("bin/hxmc/rt/windows-x86_64"), extracted + "/windows-x86_64"]);
		r = build("windows-x86_64", cross, extracted);
		check("HXMC_RT_DIR with windows-x86_64's objects: the cross build", r.code == 0 && FileSystem.exists(cross), r.out);
		r = build(host.target, app, extracted);
		check("HXMC_RT_DIR with windows-x86_64's objects: the host's still found", r.code == 0 && exec([app]).out == "hi\n", r.out);

		if (failures == 0) rmrf(dir);
		Sys.println(failures == 0 ? "RtSearchCheck: ok" : 'RtSearchCheck: $failures failed (in $dir)');
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
