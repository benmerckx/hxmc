package macros.eval;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import core.ds.Failure;

// port: haxe/libs/extc/process.ml: the subprocesses behind Eval's sys.io.Process,
// over the host's sys.io.Process.
//
// Upstream spawns with Unix.create_process (posix_spawnp). When that fails
// because the command is not found, `run` returns a process whose stdout is
// at EOF, whose stderr holds the error message and whose exit code is 127.
// Host processes fork first and report a failed exec only through their own
// exit code (1 on HashLink), so the command is looked up in PATH here, as
// posix_spawnp does, before the host process is created.
class EvalProcess {
	final host:Null<sys.io.Process>;
	final failedStderr:Null<BytesInput>;
	var exitCode:Null<Int>;
	// port: closeStdin happened: close leaves stdin alone (upstream closes it again,
	// ... ignoring EBADF, but the number may belong to another descriptor by then, opened
	// ... by another thread of the host: closing it again would break that one)
	var stdinClosed = false;
	// port: close happened (upstream closes again, ignoring the errors)
	var closed = false;

	function new(host:Null<sys.io.Process>, failedStderr:Null<BytesInput>, exitCode:Null<Int>) {
		this.host = host;
		this.failedStderr = failedStderr;
		this.exitCode = exitCode;
	}

	public static function run(cmd:String, args:Null<Array<String>>):EvalProcess {
		// port: with args = None upstream runs /bin/sh -c (cmd.exe on Windows), which always exists
		if (args != null && Sys.systemName() != "Windows" && !commandExists(cmd)) {
			return failed(cmd);
		}
		// port: on Windows the host's process creation fails as Unix.create_process does
		// ... (CreateProcess with the program SearchPath found); the error is taken to be
		// ... ENOENT, the failure of a program that is not found
		if (args != null && Sys.systemName() == "Windows") {
			return try new EvalProcess(new sys.io.Process(cmd, args), null, null) catch (_:Dynamic) failed(cmd);
		}
		return new EvalProcess(new sys.io.Process(cmd, args), null, null);
	}

	static function failed(cmd:String):EvalProcess {
		var msg = "create_process(" + cmd + "): No such file or directory\n";
		return new EvalProcess(null, new BytesInput(Bytes.ofString(msg)), 127);
	}

	// port: the execvp/posix_spawnp lookup: a path with a slash is used as is, otherwise PATH is searched.
	static function commandExists(cmd:String):Bool {
		inline function isExecutableFile(path:String):Bool {
			// port: 73 = 0o111: some execute bit
			return sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path) && (sys.FileSystem.stat(path).mode & 73) != 0;
		}
		// port: PATHEXT is only set on Windows, where the Cosmopolitan build of the
		// ... port (Sys.systemName() is "Linux" there) also finds programs by extension
		var pathExt = Sys.getEnv("PATHEXT");
		var exts = pathExt == null ? [""] : [""].concat(pathExt.split(";"));
		if (cmd.indexOf("/") >= 0 || (pathExt != null && cmd.indexOf("\\") >= 0)) {
			for (ext in exts)
				if (sys.FileSystem.exists(cmd + ext))
					return true;
			return false;
		}
		if (cmd == "")
			return false;
		var path = Sys.getEnv("PATH");
		if (path == null)
			path = "/bin:/usr/bin";
		for (dir in path.split(":"))
			for (ext in exts)
				if (isExecutableFile((dir == "" ? "." : dir) + "/" + cmd + ext))
					return true;
		return false;
	}

	public function readStdout(b:Bytes, pos:Int, len:Int):Int {
		if (host == null)
			throw new Failure("process_stdout_read");
		return host.stdout.readBytes(b, pos, len);
	}

	public function readStderr(b:Bytes, pos:Int, len:Int):Int {
		if (host == null)
			return failedStderr.readBytes(b, pos, len);
		return host.stderr.readBytes(b, pos, len);
	}

	public function writeStdin(b:Bytes, pos:Int, len:Int):Int {
		if (host == null)
			throw new Failure("write(): Broken pipe");
		return host.stdin.writeBytes(b, pos, len);
	}

	public function closeStdin():Void {
		// port: a second close_stdin fails with EBADF upstream (unless the number was reused)
		if (stdinClosed)
			throw new Failure("close(): Bad file descriptor");
		stdinClosed = true;
		if (host != null)
			host.stdin.close();
	}

	public function exit():Int {
		if (exitCode == null)
			exitCode = host.exitCode(true);
		return exitCode;
	}

	public function pid():Int {
		return host == null ? 0 : host.getPid();
	}

	public function close():Void {
		if (host == null || closed) return;
		closed = true;
		if (!stdinClosed) {
			stdinClosed = true;
			host.stdin.close();
		}
		host.stdout.close();
		host.stderr.close();
	}

	public function kill():Void {
		if (host != null && exitCode == null)
			host.kill();
	}
}
