// hxmc.NativeSys.processSignal: SIGTERM and SIGINT, which a child can trap,
// besides SIGKILL (processKill). A child ended by a signal exits with 128 +
// the signal's number, on Windows too, where every signal is
// TerminateProcess with that code. The child is /bin/sh on Linux and macOS,
// cmd.exe on Windows, waiting for a line of its stdin. Windows has no traps: there the
// last two lines are printed as they are elsewhere. The corpus runs a case
// as a background job of a non-interactive shell (Harness.exec), which
// ignores SIGINT, and a child inherits that through fork and exec, and a
// shell cannot trap a signal ignored when it started: the program sets
// SIGINT back to its default first.
import hxmc.NativeSys;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;

class ProcessSignals {
	static function main() {
		var win = Sys.systemName() == "Windows";
		if (Mem.os() <= 1) Posix.signal(NativeSys.SIGINT, Ptr.nil()); // SIG_DFL (Linux, macOS)
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
			var c = start(win, "trap 'echo int; exit 4' INT; " + loop);
			NativeSys.processSignal(c.pid, NativeSys.SIGINT);
			Sys.println("SIGINT trapped: " + finish(c));
		} else Sys.println("SIGTERM trapped: term 3\nSIGINT trapped: int 4");
	}

	// a child that printed "ready"
	static function start(win:Bool, script:String) {
		var fds = [0, 0, 0];
		var pid = win ? NativeSys.processRun("cmd", ["/c", "echo ready& set /p x="], fds) : NativeSys.processRun("/bin/sh", ["-c", script], fds);
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
