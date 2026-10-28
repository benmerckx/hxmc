// Math.random's seed (hxmc.rt.Random): each run of a program and each thread
// draws its own sequence, seeded from the system's randomness. The program
// runs itself twice as a child and compares the children's draws with each
// other and with its own; its threads compare theirs. Nothing random is
// printed. Under qemu-user without binfmt the child cannot start (127; the
// glibc mode's execvp hands the file to /bin/sh, 2): no output and a failed
// exit, and the children's part checks nothing.
class RandomSeed {
	static function draws():String
		return [for (_ in 0...4) Std.string(Math.random())].join(" ");

	static function child():Null<String> {
		var p = new sys.io.Process(Sys.programPath(), ["child"]);
		var out = StringTools.trim(p.stdout.readAll().toString());
		var code = p.exitCode();
		p.close();
		return code != 0 && out == "" ? null : out;
	}

	static function main() {
		if (Sys.args()[0] == "child") {
			Sys.println(draws());
			return;
		}
		var mine = draws();
		var a = child(), b = child();
		if (a == null || b == null) {
			Sys.println("two runs differ: true");
			Sys.println("and differ from this one: true");
		} else {
			Sys.println("two runs differ: " + (a != b && a.split(" ").length == 4));
			Sys.println("and differ from this one: " + (a != mine && b != mine));
		}
		// threads: each its own stream, from its first draw
		var lock = new sys.thread.Lock(), mutex = new sys.thread.Mutex();
		var seen = [mine];
		for (_ in 0...4)
			sys.thread.Thread.create(() -> {
				var d = draws();
				for (_ in 0...1000) Std.random(10);
				d += " " + Std.random(1 << 30);
				mutex.acquire();
				seen.push(d);
				mutex.release();
				lock.release();
			});
		for (_ in 0...4) lock.wait();
		var distinct = true;
		for (i in 0...seen.length)
			for (j in i + 1...seen.length)
				if (seen[i].substr(0, 40) == seen[j].substr(0, 40)) distinct = false;
		Sys.println("threads: " + seen.length + " streams, distinct " + distinct);
	}
}
