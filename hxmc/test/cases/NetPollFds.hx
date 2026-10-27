// hxmc.net.Poll over descriptors that are not sockets: a process's pipes.
// Windows' WSAPoll waits for sockets only: there inputFd and outputFd, and
// wait on a descriptor that is not a socket, fail with a clear error, and
// the pipe part prints the lines it prints elsewhere.
import hxmc.net.Poll;
import sys.io.Process;

class NetPollFds {
	static function socketsOnly(e:haxe.io.Error):Bool
		return switch e {
			case Custom(m): (m : String).indexOf("sockets only") >= 0;
			case _: false;
		}

	static function main() {
		var windows = Sys.systemName() == "Windows";
		// a file's stream
		var path = Sys.getCwd() + "/NetPollFds.tmp";
		var out = sys.io.File.write(path);
		var file = try {
			Poll.outputFd(out) >= 0 && !windows;
		} catch (e:haxe.io.Error) windows && socketsOnly(e);
		out.close();
		sys.FileSystem.deleteFile(path);
		Sys.println("file: " + file);
		var raw = try {
			Poll.wait([0], [Poll.IN], [0], 1, 0);
			!windows;
		} catch (e:haxe.io.Error) windows && socketsOnly(e);
		Sys.println("a descriptor that is not a socket: " + raw);
		if (windows) {
			Sys.println("2 [0,4]\n1 1\ngot x\ntrue\nCustom(Poll.inputFd: the stream is closed)");
			return;
		}
		var p = new Process("sh", ["-c", "read x; echo got $x"]);
		var fds = [Poll.inputFd(p.stdout), Poll.outputFd(p.stdin)];
		var events = [Poll.IN, Poll.OUT], revents = [0, 0];
		// the child waits for a line: its stdin is writable, its stdout empty
		Sys.println(fds.length + " " + (Poll.wait(fds, events, revents, 2, 0) == 1 ? revents : null));
		p.stdin.writeString("x\n");
		p.stdin.flush();
		Sys.println(Poll.wait(fds, events, revents, 1, 5.0) + " " + (revents[0] & Poll.IN));
		Sys.println(p.stdout.readLine());
		// the child has exited: its stdout ends
		p.exitCode();
		Poll.wait(fds, events, revents, 1, 5.0);
		Sys.println((revents[0] & (Poll.IN | Poll.HUP)) != 0);
		p.close();
		try {
			Poll.inputFd(p.stdout);
		} catch (e:haxe.io.Error) {
			Sys.println(e);
		}
	}
}
