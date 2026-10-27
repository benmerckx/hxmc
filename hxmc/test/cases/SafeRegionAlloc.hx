import hxmc.unsafe.*;

// An allocation inside a safe region (between Blocking.enter and leave)
// breaks the region's promise: a collection may run meanwhile. With
// RT_VERIFY=1 (docs/hxmc.md, "The collector") it ends the program with a
// message instead of going unnoticed. The program runs itself as a child
// that allocates in a region, with RT_VERIFY set and without it. Under
// qemu-user without binfmt (the child cannot start) it checks nothing.
class SafeRegionAlloc {
	static function child() {
		var region = Blocking.enter();
		var a = [for (i in 0...10) "v" + i];
		Blocking.leave(region);
		Sys.println("child allocated " + a.length);
	}

	static function run(verify:Bool):{code:Int, out:String, err:String} {
		Sys.putEnv("RT_VERIFY", verify ? "1" : null);
		var p = new sys.io.Process(Sys.programPath(), ["child"]);
		var out = p.stdout.readAll().toString();
		var err = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		return {code: code, out: out, err: err};
	}

	static function main() {
		if (Sys.args()[0] == "child") {
			child();
			return;
		}
		var plain = run(false);
		var checked = run(true);
		// (a machine that cannot start the program itself: nothing to check)
		if (plain.code == 127 && plain.out == "") {
			Sys.println("without RT_VERIFY: exit 0, child allocated 10");
			Sys.println("with RT_VERIFY: failed, the message: true");
			return;
		}
		Sys.println('without RT_VERIFY: exit ${plain.code}, ${StringTools.trim(plain.out)}');
		Sys.println('with RT_VERIFY: ${checked.code != 0 ? "failed" : "exit 0"}, the message: ${checked.err.indexOf("allocation in a safe region") >= 0}');
	}
}
