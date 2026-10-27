// hxmc.NativeSys.processExitFd: on Linux a pidfd (pidfd_open), a descriptor
// that becomes readable when the process exits, so an event loop learns of
// the exit by polling it with its other descriptors instead of calling
// waitpid on every round. Elsewhere it is -1 (macOS and Windows have their
// own mechanisms, not exposed yet), and the Linux lines are printed as they
// are there.
import hxmc.NativeSys;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

@:hxmc.c @:hxmc.fast extern class ProcessExitFdC {
	static function poll(fds:Ptr, n:Int, ms:Int):Int;
}

class ProcessExitFd {
	static function main() {
		if (Mem.os() != 0) {
			var fds = [0, 0, 0];
			var win = Sys.systemName() == "Windows";
			if (Sys.systemName() != "Wasi") {
				var pid = win ? NativeSys.processRun("cmd", ["/c", "exit 0"], fds) : NativeSys.processRun("/bin/sh", ["-c", "exit 0"], fds);
				Sys.println("elsewhere: " + NativeSys.processExitFd(pid));
				NativeSys.processWait(pid, true);
			} else Sys.println("elsewhere: " + NativeSys.processExitFd(1)); // (no processes)
			Sys.println("exit fd: true\nrunning: true\nexited: true\nexit: 0\nreaped: -1");
		} else linux();
	}

	static function linux() {
		Sys.println("elsewhere: -1");
		var fds = [0, 0, 0];
		var pid = NativeSys.processRun("/bin/sh", ["-c", "read x; exit 0"], fds);
		var fd = NativeSys.processExitFd(pid);
		Sys.println("exit fd: " + (fd >= 0));
		Sys.println("running: " + !ready(fd, 0));
		NativeSys.fileClose(fds[0]);
		Sys.println("exited: " + ready(fd, 10000));
		Sys.println("exit: " + NativeSys.processWait(pid, true));
		NativeSys.fileClose(fd);
		NativeSys.fileClose(fds[1]);
		NativeSys.fileClose(fds[2]);
		Sys.println("reaped: " + NativeSys.processExitFd(pid));
	}

	// struct pollfd: fd, events, revents (POLLIN 1)
	static function ready(fd:Int, ms:Int):Bool {
		var p = Mem.stack(8);
		Mem.setI32(p, 0, fd);
		Mem.setI16(p, 4, 1);
		Mem.setI16(p, 6, 0);
		return ProcessExitFdC.poll(p, 1, ms) == 1 && (Mem.getU16(p, 6) & 1) != 0;
	}
}
