// A read of a non-blocking pipe with no data would block: NativeSys.fileRead
// says so (NativeSys.WOULD_BLOCK), distinct from an error (-1) and from the
// end (0), and sys.io.FileInput throws haxe.io.Error.Blocked. Also with a
// second thread running, where reads wait for their descriptor in a safe
// region first: a non-blocking descriptor must not wait. The child echoes
// a line of its stdin: /bin/sh on Linux and macOS, cmd.exe on Windows (a
// pipe in PIPE_NOWAIT mode).
import hxmc.NativeSys;
import sys.thread.Lock;
import sys.thread.Thread;

class NonBlockingRead {
	static function main() {
		round("");
		var lock = new Lock();
		Thread.create(() -> lock.wait());
		round("threads: ");
		lock.release();
	}

	static function round(prefix:String) {
		var win = Sys.systemName() == "Windows";
		var fds = [0, 0, 0];
		var pid = win ? NativeSys.processRun("cmd", ["/v:on", "/c", "set /p x=& echo got !x!"], fds) : NativeSys.processRun("/bin/sh", ["-c", "read x; echo \"got $x\""], fds);
		var b = haxe.io.Bytes.alloc(64);
		Sys.println(prefix + "non-blocking: " + NativeSys.fileSetBlocking(fds[1], false));
		Sys.println(prefix + "nothing yet: " + (NativeSys.fileRead(fds[1], b, 0, 64) == NativeSys.WOULD_BLOCK));
		var input = @:privateAccess new sys.io.FileInput(fds[1]);
		try {
			input.readBytes(b, 0, 64);
			Sys.println(prefix + "FileInput: read");
		} catch (e:haxe.io.Error) {
			Sys.println(prefix + "FileInput: " + e);
		}
		var output = @:privateAccess new sys.io.FileOutput(fds[0]);
		output.writeString("hi\n");
		output.close();
		// the line, then the end, polling
		var got = new StringBuf();
		var t0 = Sys.time(), blocked = 0;
		while (Sys.time() - t0 < 30) {
			var n = NativeSys.fileRead(fds[1], b, 0, 64);
			if (n == NativeSys.WOULD_BLOCK) {
				blocked++;
				Sys.sleep(0.01);
				continue;
			}
			if (n <= 0) {
				Sys.println(prefix + "end: " + n);
				break;
			}
			got.add(b.getString(0, n));
		}
		Sys.println(prefix + "read: " + StringTools.trim(got.toString()));
		input.close();
		NativeSys.fileClose(fds[2]);
		Sys.println(prefix + "exit: " + NativeSys.processWait(pid, true));
		// an error is not a would-block: a file open for writing only
		var fd = NativeSys.fileOpen("nonblockingread.tmp", 1);
		Sys.println(prefix + "write-only: " + NativeSys.fileRead(fd, b, 0, 64));
		NativeSys.fileClose(fd);
		sys.FileSystem.deleteFile("nonblockingread.tmp");
	}
}
