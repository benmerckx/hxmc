package macros.eval;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import core.ds.Failure;
#if (target.name == "hxmc")
import hxmc.NativeSys;
import hxmc.NativeUv as Uv;
#end

/** Subprocess management on libuv ({!Luv.Process}), without C stubs of our own.

	Replaces the former C stubs (process_stubs.c) which were unsafe under
	OCaml 5 multi-domain execution (missing [caml_enter_blocking_section],
	direct [fork()] in multi-threaded processes).

	[Unix.create_process] cannot start a process in another directory, and
	the directory of this process is shared by all its threads and domains,
	which is why processes are started by libuv. The pipes are libuv's too,
	read and written with blocking calls.

	When the command is not found, [run] returns a process whose pipes
	immediately return EOF and whose [exit] returns code 127 (matching
	the POSIX shell convention and the old fork+exec behavior where
	fork always succeeded). */
// port: haxe/libs/extc/process.ml. On hxmc a process with pipes is hxmc's fork and
// ... exec (hxmc.NativeSys.processRun, in a directory if given), whose child can only
// ... end with 127 when it fails: the errors libuv's spawn reports from its child (the
// ... directory entered, then the program executed, as execvp looks for it) are found
// ... here before it starts (spawnError). A shell command in a directory with this
// ... process's descriptors (command) is libuv's spawn, as upstream's (hxmc.NativeUv).
// ... Other hosts (the port is compiled for them, not run there) use the host's
// ... sys.io.Process, through /bin/sh in another directory.
class EvalProcess {
	// port: the parent's ends of the pipes; stdout null when the process did not
	// ... start (stderr then holds the error)
	final stdin:Null<haxe.io.Output>;
	final stdout:Null<haxe.io.Input>;
	final stderr:haxe.io.Input;
	final processId:Int;
	#if (target.name != "hxmc")
	final host:Null<sys.io.Process>;
	#end
	var exitCode:Null<Int>;
	// port: close_stdin happened (upstream's stdin becomes None)
	var stdinClosed = false;
	// port: close happened (upstream's pipes become None)
	var closed = false;

	function new(stdin:Null<haxe.io.Output>, stdout:Null<haxe.io.Input>, stderr:haxe.io.Input, processId:Int,
			#if (target.name != "hxmc") host:Null<sys.io.Process>, #end exitCode:Null<Int>) {
		this.stdin = stdin;
		this.stdout = stdout;
		this.stderr = stderr;
		this.processId = processId;
		#if (target.name != "hxmc")
		this.host = host;
		#end
		this.exitCode = exitCode;
	}

	/* The program and arguments that run the shell command [cmd], with whether
		Windows must get them as they are. */
	static function shell(cmd:String):{prog:String, argv:Array<String>, verbatim:Bool} {
		return if (Sys.systemName() == "Windows") {
			/* cmd.exe must get the command line as is, not re-quoted as an argv entry */
			var shell = Sys.getEnv("COMSPEC");
			if (shell == null) shell = "cmd.exe";
			{prog: shell, argv: [core.OcamlFilename.quote(shell), "/c", cmd], verbatim: true};
		} else {prog: "/bin/sh", argv: ["/bin/sh", "-c", cmd], verbatim: false};
	}

	/** Runs [cmd] with [args], or the shell command [cmd] if [args] is [None], in
		directory [cwd] if given, without changing the directory of this process.
		Its standard descriptors are new pipes. */
	public static function run(cmd:String, args:Null<Array<String>>, ?cwd:String):EvalProcess {
		var prog = args == null ? shell(cmd).prog : cmd;
		var error = spawnError(prog, args != null, cwd);
		if (error != null) return failed(prog, error);
		return try start(cmd, args, cwd) catch (_:Dynamic) failed(prog, ENOENT);
	}

	/* Process creation failed (e.g. command not found).
		Match the old fork+exec behavior: the pipes immediately return EOF
		and the exit code is 127. The error message is written to the
		stderr pipe so callers can read it. */
	static function failed(prog:String, error:String):EvalProcess {
		var msg = prog + ": " + error + "\n";
		return new EvalProcess(null, null, new BytesInput(Bytes.ofString(msg)), 0, #if (target.name != "hxmc") null, #end 127);
	}

	// port: libuv's messages (Luv.Error.strerror) of the errors a spawn reports
	static inline final ENOENT = "no such file or directory";
	static inline final ENOTDIR = "not a directory";
	static inline final EACCES = "permission denied";

	// port: the error libuv's spawn reports from its child, which enters [cwd] (chdir),
	// ... then executes the program (execvp: a name without a slash is looked up on PATH,
	// ... a candidate that exists but cannot be executed gives EACCES unless a later one
	// ... runs); null when it would start. Windows: the directory only, the host's process
	// ... creation fails as libuv's search does (taken to be ENOENT, see run)
	static function spawnError(prog:String, direct:Bool, cwd:Null<String>):Null<String> {
		if (cwd != null) {
			if (!sys.FileSystem.exists(cwd)) return ENOENT;
			if (!sys.FileSystem.isDirectory(cwd)) return ENOTDIR;
		}
		if (!direct || Sys.systemName() == "Windows") return null;
		inline function at(path:String):String return cwd != null && core.OcamlFilename.isRelative(path) ? cwd + "/" + path : path;
		// port: PATHEXT is only set on Windows, where the Cosmopolitan build of the
		// ... port (Sys.systemName() is "Linux" there) also finds programs by extension
		var pathExt = Sys.getEnv("PATHEXT");
		var exts = pathExt == null ? [""] : [""].concat(pathExt.split(";"));
		function attempt(path:String):Null<String> {
			var error = ENOENT;
			for (ext in exts) {
				var p = at(path + ext);
				if (!sys.FileSystem.exists(p)) continue;
				// port: 73 = 0o111: some execute bit
				if (sys.FileSystem.isDirectory(p) || (sys.FileSystem.stat(p).mode & 73) == 0) error = EACCES else return null;
			}
			return error;
		}
		if (prog.indexOf("/") >= 0 || (pathExt != null && prog.indexOf("\\") >= 0)) return attempt(prog);
		if (prog == "") return ENOENT;
		var path = Sys.getEnv("PATH");
		if (path == null) path = "/bin:/usr/bin";
		var eacces = false;
		for (dir in path.split(":")) {
			switch attempt(dir == "" ? prog : dir + "/" + prog) {
				case null: return null;
				case e: if (e == EACCES) eacces = true;
			}
		}
		return eacces ? EACCES : ENOENT;
	}

	// port: starts the process on new pipes; throws when the host cannot
	static function start(cmd:String, args:Null<Array<String>>, cwd:Null<String>):EvalProcess {
		#if (target.name == "hxmc")
		var fds = [0, 0, 0];
		var pid = NativeSys.processRun(cmd, args, fds, cwd);
		if (pid < 0) throw new Failure("process_run");
		return new EvalProcess(@:privateAccess new sys.io.FileOutput(fds[0]), @:privateAccess new sys.io.FileInput(fds[1]),
			@:privateAccess new sys.io.FileInput(fds[2]), pid, null);
		#else
		var host = if (cwd == null) new sys.io.Process(cmd, args) else {
			if (Sys.systemName() == "Windows") throw new Failure("port: a process in another directory needs hxmc's processes on Windows");
			if (args == null) new sys.io.Process("/bin/sh", ["-c", "cd \"$0\" && " + cmd, cwd]) else
				new sys.io.Process("/bin/sh", ["-c", "cd \"$0\" && exec \"$@\"", cwd, cmd].concat(args));
		}
		return new EvalProcess(host.stdin, host.stdout, host.stderr, host.getPid(), host, null);
		#end
	}

	/** As Sys.command, the shell command [cmd] with the standard descriptors of
		this process, in directory [cwd] if given. */
	public static function command(cmd:String, ?cwd:String):Int {
		if (cwd == null) return sysCommand(cmd);
		#if (target.name == "hxmc")
		// port: hxmc has libuv except on WebAssembly, where WASI has no processes:
		// ... Sys.command's failure there
		if (!Uv.available()) return sysCommand(cmd);
		var sh = shell(cmd);
		var loop = takeLoop();
		var exitCode:Null<Int> = null;
		var exited = false;
		var flags = (sh.verbatim ? 4 : 0) | (windowsHide() ? 16 : 0);
		// port: luv's Process.inherit_fd: 0, 1 and 2 of this process as the child's
		var handle = Uv.processSpawn(loop, Bytes.ofString(sh.prog), [for (a in sh.argv) Bytes.ofString(a)], null, Bytes.ofString(cwd), flags, 0,
			0, [0, 2, 0, 0, 1, 2, 0, 1, 2, 2, 0, 2], true);
		if (handle < 0) {
			release(loop, -1);
			return 127;
		}
		/* As system(), the interrupt and quit signals are ignored while waiting for
			the child: they go to the child from the terminal. */
		NativeSys.interruptsIgnored(true);
		try {
			while (!exited)
				Uv.loopRun(loop, 1, (id, event, a, b) -> if (event == 6 && id == handle) {
					exited = true;
					/* as Sys.command: 255 for a process ended by a signal */
					exitCode = (b : Int) != 0 && Sys.systemName() != "Windows" ? 255 : a;
				});
		} catch (e:Dynamic) {
			NativeSys.interruptsIgnored(false);
			throw e;
		}
		NativeSys.interruptsIgnored(false);
		release(loop, handle);
		return exitCode;
		#else
		return if (Sys.systemName() == "Windows") Sys.command("cd /d \"" + cwd + "\" && " + cmd) else
			Sys.command("cd " + haxe.SysTools.quoteUnixArg(cwd) + " && " + cmd);
		#end
	}

	// port: OCaml's Sys.command (system(), 255 for a process ended by a signal)
	static function sysCommand(cmd:String):Int {
		#if (target.name == "hxmc")
		var r = NativeSys.commandStatus(cmd);
		return r >= 256 && Sys.systemName() != "Windows" ? 255 : r;
		#else
		return Sys.command(cmd);
		#end
	}

	#if (target.name == "hxmc")
	/* As Unix.create_process on Windows: without a console, the process gets a
		hidden one. */
	static function windowsHide():Bool {
		if (Sys.systemName() != "Windows") return false;
		// port: Unix.openfile "CONOUT$" [O_WRONLY]; hxmc's update mode (read and write) opens a console's output
		var fd = NativeSys.fileOpen("CONOUT$", 3);
		if (fd < 0) return true;
		NativeSys.fileClose(fd);
		return false;
	}

	/* Loops are kept for the next process instead of being closed. On Linux,
		closing one ends its io_uring instance, and the kernel then interrupts a
		later blocking system call of this thread: a connect or a read on a socket
		with a timeout fails with EINTR. */
	static final freeLoops:Array<Int> = [];
	static final freeLoopsMutex = new sys.thread.Mutex();

	static function takeLoop():Int {
		freeLoopsMutex.acquire();
		var loop = freeLoops.pop();
		freeLoopsMutex.release();
		if (loop != null) return loop;
		var loop = Uv.loopInit();
		if (loop < 0) throw new Failure("uv_loop_init");
		return loop;
	}

	/* Closes the handle of [p] and gives its loop back once nothing is left on
		it. To call once per process. */
	static function release(loop:Int, handle:Int):Void {
		if (handle >= 0) Uv.handleClose(handle);
		Uv.loopRun(loop, 0, (_, _, _, _) -> {});
		freeLoopsMutex.acquire();
		freeLoops.push(loop);
		freeLoopsMutex.release();
	}
	#end

	public function readStdout(b:Bytes, pos:Int, len:Int):Int {
		if (stdout == null || closed)
			throw new Failure("process_stdout_read");
		return stdout.readBytes(b, pos, len);
	}

	public function readStderr(b:Bytes, pos:Int, len:Int):Int {
		if (closed)
			throw new Failure("process_stderr_read");
		return stderr.readBytes(b, pos, len);
	}

	public function writeStdin(b:Bytes, pos:Int, len:Int):Int {
		if (stdinClosed)
			throw new Failure("process_stdin_write");
		// port: a process that did not start has a pipe nobody reads (EPIPE); a
		// ... failed write is libuv's EPIPE, the error of a reader that is gone
		if (stdin == null)
			throw new Failure("broken pipe");
		return try stdin.writeBytes(b, pos, len) catch (_:Dynamic) throw new Failure("broken pipe");
	}

	public function closeStdin():Void {
		if (stdinClosed) return;
		stdinClosed = true;
		if (stdin != null)
			stdin.close();
	}

	public function exit():Int {
		if (exitCode == null)
			exitCode = waitExit();
		return exitCode;
	}

	// port: wait: the exit code, 255 for a process ended by a signal (as Sys.command)
	function waitExit():Int {
		#if (target.name == "hxmc")
		var s = NativeSys.processWaitStatus(processId, true);
		return s >= 256 && Sys.systemName() != "Windows" ? 255 : s;
		#else
		return host.exitCode(true);
		#end
	}

	public function pid():Int {
		return processId;
	}

	public function close():Void {
		if (closed) return;
		closed = true;
		closeStdin();
		if (stdout != null) {
			stdout.close();
			stderr.close();
		}
	}

	public function kill():Void {
		if (stdout != null && exitCode == null) {
			#if (target.name == "hxmc")
			NativeSys.processKill(processId);
			#else
			host.kill();
			#end
		}
	}
}
