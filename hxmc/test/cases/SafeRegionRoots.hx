// References live across a safe region the runtime's code enters itself
// (Leaf.rt_blocking_enter and rt_blocking_leave, @:hxmc.fast C functions)
// are in their slots before it and read back after it (GcPoints): WinSys's
// read of a pipe with other threads running copied the data into the Bytes
// it was given, which a collection on another thread had moved meanwhile, so
// the reader lost it (the Windows corpus check lost a program's output now
// and then, depending on the collections' timing). The program runs itself
// as a child, reads the child's stdout here and its stderr on another thread
// that allocates meanwhile, as the harness on Windows does. Natively on
// Linux and macOS the reads are blocking C calls (rooted already); on
// Windows (and under Wine) this read failed some rounds of a hundred. The
// golden file is hand-written: the reference's --interp has no executable
// to run as the child. Under qemu-user without binfmt (the child cannot
// start) it checks nothing.
import sys.thread.Lock;
import sys.thread.Thread;

class SafeRegionRoots {
	static function main() {
		var args = Sys.args();
		if (args.length > 0 && args[0] == "child") {
			var n = Std.parseInt(args[1]);
			for (i in 0...n)
				Sys.println("line " + i + " of the child's output, padded to be a bit longer");
			Sys.stderr().writeString("err\n");
			return;
		}
		var self = Sys.programPath();
		var rounds = 100, bad = 0;
		for (r in 0...rounds) {
			var n = 1 + r % 40;
			var p = new sys.io.Process(self, ["child", "" + n]);
			var lock = new Lock();
			var err = "";
			Thread.create(() -> {
				err = p.stderr.readAll().toString();
				// (garbage: this thread collects while the other reads)
				var junk = [for (i in 0...2000) "x" + i];
				if (junk.length != 2000) err = "?";
				lock.release();
			});
			var out = p.stdout.readAll().toString();
			lock.wait();
			var code = p.exitCode();
			p.close();
			var lines = out.split("\n").length - 1;
			// (a machine that cannot start the program itself, qemu-user without
			// binfmt: nothing to check)
			if (r == 0 && code == 127 && out == "" && err == "") break;
			if (lines != n || err != "err\n" || code != 0) {
				bad++;
				Sys.println('round $r: $lines lines of $n, stderr ${err.length} characters, exit $code');
			}
		}
		Sys.println('$bad of $rounds rounds lost output');
	}
}
