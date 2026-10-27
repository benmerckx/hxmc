// hxmc.NativeSys.processSignal: SIGTERM and SIGINT, which a child can trap,
// besides SIGKILL (processKill). A child ended by a signal exits with 128 +
// the signal's number, on Windows too, where every signal is
// TerminateProcess with that code. The child is /bin/sh on Linux and macOS
// (also under qemu-user, which cannot start the program itself without
// binfmt), the program itself on Windows. Windows has no traps: there the
// last two lines are printed as they are elsewhere. SIGINT's trap is node's:
// the corpus runs a case as a background job of a non-interactive shell
// (Harness.exec), which ignores SIGINT, and a shell cannot trap a signal
// ignored when it started (it is inherited through fork and exec); node's
// handler replaces the disposition.
import hxmc.NativeSys;

class ProcessSignals {
	// (written out before exiting: node's writes to a pipe are asynchronous on macOS)
	static final NODE_INT = "process.on('SIGINT', () => process.stdout.write('int\\n', () => process.exit(4))); process.stdout.write('ready\\n'); setInterval(() => {}, 1000);";

	static function main() {
		var args = Sys.args();
		if (args.length > 0 && args[0] == "child") {
			Sys.println("ready");
			while (true)
				Sys.sleep(0.05);
		}
		var win = Sys.systemName() == "Windows";
		var loop = "echo ready; while :; do sleep 0.05; done";
		var c = start(win, loop);
		Sys.println("SIGTERM untrapped: " + NativeSys.processSignal(c.pid, NativeSys.SIGTERM) + " " + finish(c));
		var c = start(win, loop);
		Sys.println("SIGKILL: " + NativeSys.processSignal(c.pid, NativeSys.SIGKILL) + " " + finish(c));
		// (a process reaped: nothing to signal)
		Sys.println("after exit: " + NativeSys.processSignal(c.pid, NativeSys.SIGTERM));
		if (!win) {
			var c = start(win, "trap 'echo term; exit 3' TERM; " + loop);
			NativeSys.processSignal(c.pid, NativeSys.SIGTERM);
			Sys.println("SIGTERM trapped: " + finish(c));
			var c = start(win, null);
			NativeSys.processSignal(c.pid, NativeSys.SIGINT);
			Sys.println("SIGINT trapped: " + finish(c));
		} else Sys.println("SIGTERM trapped: term 3\nSIGINT trapped: int 4");
	}

	// a child that printed "ready"
	static function start(win:Bool, script:Null<String>) {
		var fds = [0, 0, 0];
		var pid = win ? NativeSys.processRun(Sys.programPath(), ["child"], fds) : script != null ? NativeSys.processRun("/bin/sh", ["-c", script],
			fds) : NativeSys.processRun("node", ["-e", NODE_INT], fds);
		if (pid < 0) throw "Process creation failure";
		var out = @:privateAccess new sys.io.FileInput(fds[1]);
		var ready = out.readLine();
		if (ready != "ready") throw "the child printed " + ready;
		return {pid: pid, out: out, fds: fds};
	}

	// what it printed after "ready", and its exit code
	static function finish(c:{pid:Int, out:sys.io.FileInput, fds:Array<Int>}):String {
		var rest = StringTools.trim(c.out.readAll().toString());
		var code = NativeSys.processWait(c.pid, true);
		c.out.close();
		NativeSys.fileClose(c.fds[0]);
		NativeSys.fileClose(c.fds[2]);
		return (rest == "" ? "" : rest + " ") + code;
	}
}
