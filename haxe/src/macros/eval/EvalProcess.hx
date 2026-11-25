package macros.eval;

import haxe.io.Bytes;
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
// port: haxe/libs/extc/process.ml, on the libuv that hxmc bundles. Loops,
// ... process handles and files are integer ids here.
#if (target.name == "hxmc")
class EvalProcess {
	/* A process runs on a loop that is its own until it has exited. */
	final loop:Int;
	var handle:Null<Int> = null; // None if not started, or closed
	var processId = 0;
	var stdin:Null<Int> = null; // None once closed
	var stdout:Null<Int> = null;
	var stderr:Null<Int> = null;
	var exitCode:Null<Int> = null;

	// port: luv's file operations, as hxmc.rt.Uv numbers them
	static inline final FS_CLOSE = 1;
	static inline final FS_READ = 2;
	static inline final FS_WRITE = 3;
	// port: luv's Loop.run modes
	static inline final RUN_DEFAULT = 0;
	static inline final RUN_ONCE = 1;
	// port: hxmc.rt.Uv's event for a process that exited
	static inline final EV_EXIT = 6;
	static inline final SIGKILL = 9;

	static function luvOk(r:Int):Int {
		if (r < 0) throw new SpawnError(Uv.strerror(r));
		return r;
	}

	static function closeFile(file:Int):Void {
		fsSync(FS_CLOSE, file, null, 0);
	}

	// port: luv's File.Sync calls: the result, or a negative error
	static function fsSync(op:Int, file:Int, data:Null<Bytes>, len:Int, ?into:Bytes, pos:Int = 0):Int {
		var req = Uv.reqNew();
		var r = Uv.fs(op, -1, req, null, null, file, 0, 0, -1, 0, data, op == FS_CLOSE ? null : [len]);
		if (r >= 0) r = Uv.fsResult(req);
		if (op == FS_READ && r > 0) Uv.reqCopyOut(req, into, pos, 0, r);
		Uv.fsCleanup(req);
		Uv.reqFree(req);
		return r;
	}

	/* As Unix.create_process on Windows: without a console, the process gets a
		hidden one. */
	static function windowsHide():Bool {
		if (Sys.systemName() != "Windows") return false;
		// port: Unix.openfile "CONOUT$" [O_WRONLY]; hxmc's mode 3 opens for reading and writing, which a console's output allows
		var fd = NativeSys.fileOpen("CONOUT$", 3);
		if (fd < 0) return true;
		NativeSys.fileClose(fd);
		return false;
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
		return loop != null ? loop : luvOk(Uv.loopInit());
	}

	function new() {
		loop = takeLoop();
	}

	// port: on_exit, called while the loop runs
	function onEvent(id:Int, event:Int, exitStatus:Int, termSignal:Dynamic):Void {
		if (event == EV_EXIT && id == handle)
			/* as Sys.command: 255 for a process ended by a signal */
			exitCode = (termSignal : Int) != 0 && Sys.systemName() != "Windows" ? 255 : exitStatus;
	}

	/* Closes the handle of [p] and gives its loop back once nothing is left on
		it. To call once per process. */
	function release():Void {
		if (handle != null) Uv.handleClose(handle);
		handle = null;
		Uv.loopRun(loop, RUN_DEFAULT, onEvent);
		freeLoopsMutex.acquire();
		freeLoops.push(loop);
		freeLoopsMutex.release();
	}

	/* Starts [cmd] with [args], or the shell command [cmd] if [args] is [None],
		as process [p] with the descriptors [fd0], [fd1] and [fd2] of this process
		as its standard ones. */
	function spawn(cwd:Null<String>, cmd:String, args:Null<Array<String>>, fd0:Int, fd1:Int, fd2:Int):Void {
		var s = args == null ? shell(cmd) : {prog: cmd, argv: [cmd].concat(args), verbatim: false};
		// port: hxmc.rt.Uv's redirections: (child fd, 2 = inherit_fd, 0, parent fd) each
		var redirect = [0, 2, 0, fd0, 1, 2, 0, fd1, 2, 2, 0, fd2];
		// port: hxmc.rt.Uv's flags: 4 windows_verbatim_arguments, 16 windows_hide
		var flags = (s.verbatim ? 4 : 0) | (windowsHide() ? 16 : 0);
		var h = Uv.processSpawn(loop, Bytes.ofString(s.prog), [for (a in s.argv) Bytes.ofString(a)], null,
			cwd == null ? null : Bytes.ofString(cwd), flags, 0, 0, redirect, true);
		if (h < 0) throw new SpawnError(s.prog + ": " + Uv.strerror(h));
		handle = h;
		processId = Uv.processPid(h);
	}

	/* Waits for [p] to exit; its exit code. */
	function wait():Int {
		while (exitCode == null && handle != null)
			Uv.loopRun(loop, RUN_ONCE, onEvent);
		if (handle != null) release();
		var c = exitCode != null ? exitCode : 255;
		exitCode = c;
		return c;
	}

	static function writeFile(file:Int, b:Bytes, pos:Int, len:Int):Int {
		return fsSync(FS_WRITE, file, b.sub(pos, len), len);
	}

	/** Runs [cmd] with [args], or the shell command [cmd] if [args] is [None], in
		directory [cwd] if given, without changing the directory of this process.
		Its standard descriptors are new pipes. */
	public static function run(cmd:String, args:Null<Array<String>>, ?cwd:String):EvalProcess {
		// port: WASI has no processes, and hxmc has no libuv there
		if (!Uv.available()) throw new Failure("sys.io.Process is not supported on WASI");
		var p = new EvalProcess();
		var files = [];
		function pipe():Array<Int> {
			var fds = [0, 0];
			luvOk(Uv.pipe(0, 0, fds));
			files.push(fds[0]);
			files.push(fds[1]);
			return fds;
		}
		var childStdin, childStdout, childStderr;
		try {
			var a = pipe();
			childStdin = a[0];
			p.stdin = a[1];
			var b = pipe();
			p.stdout = b[0];
			childStdout = b[1];
			var c = pipe();
			p.stderr = c[0];
			childStderr = c[1];
		} catch (e:SpawnError) {
			for (f in files) closeFile(f);
			p.release();
			throw e;
		}
		try {
			p.spawn(cwd, cmd, args, childStdin, childStdout, childStderr);
		} catch (e:SpawnError) {
			/* Process creation failed (e.g. command not found).
				Match the old fork+exec behavior: the pipes immediately return EOF
				and the exit code is 127. The error message is written to the
				stderr pipe so callers can read it. */
			var msg = Bytes.ofString(e.message + "\n");
			writeFile(childStderr, msg, 0, msg.length);
			p.release();
			p.exitCode = 127;
		}
		closeFile(childStdin);
		closeFile(childStdout);
		closeFile(childStderr);
		return p;
	}

	/* As system(), the interrupt and quit signals are ignored while waiting for
		the child: they go to the child from the terminal. */
	static function ignoringSignals<T>(f:() -> T):T {
		NativeSys.interruptsIgnored(true);
		var r = try f() catch (e:Dynamic) {
			NativeSys.interruptsIgnored(false);
			throw e;
		}
		NativeSys.interruptsIgnored(false);
		return r;
	}

	/** As Sys.command, the shell command [cmd] with the standard descriptors of
		this process, in directory [cwd] if given. */
	public static function command(cmd:String, ?cwd:String):Int {
		if (cwd == null) return sysCommand(cmd);
		// port: WASI has no processes: this fails as Sys.command does there
		if (!Uv.available()) return sysCommand(cmd);
		var p = try {
			var p = new EvalProcess();
			try p.spawn(cwd, cmd, null, 0, 1, 2) catch (e:SpawnError) {
				p.release();
				throw e;
			}
			p;
		} catch (_:SpawnError) return 127;
		return ignoringSignals(() -> p.wait());
	}

	// port: OCaml's Sys.command: system(), and 255 for a command a signal ended
	static function sysCommand(cmd:String):Int {
		var r = NativeSys.commandStatus(cmd);
		return r >= 256 && Sys.systemName() != "Windows" ? 255 : r;
	}

	function read(name:String, file:Null<Int>, buf:Bytes, pos:Int, len:Int):Int {
		inline function fail():Int throw new Failure("process_" + name + "_read");
		if (file == null) return fail();
		var n = fsSync(FS_READ, file, null, len, buf, pos);
		if (n < 0) throw new Failure(Uv.strerror(n));
		if (n == 0) return fail();
		return n;
	}

	public function readStdout(buf:Bytes, pos:Int, len:Int):Int {
		return read("stdout", stdout, buf, pos, len);
	}

	public function readStderr(buf:Bytes, pos:Int, len:Int):Int {
		return read("stderr", stderr, buf, pos, len);
	}

	public function writeStdin(buf:Bytes, pos:Int, len:Int):Int {
		if (stdin == null) throw new Failure("process_stdin_write");
		var n = writeFile(stdin, buf, pos, len);
		if (n < 0) throw new Failure(Uv.strerror(n));
		return n;
	}

	public function closeStdin():Void {
		if (stdin != null) closeFile(stdin);
		stdin = null;
	}

	public function exit():Int {
		return exitCode != null ? exitCode : wait();
	}

	public function pid():Int {
		return processId;
	}

	public function close():Void {
		closeStdin();
		if (stdout != null) closeFile(stdout);
		stdout = null;
		if (stderr != null) closeFile(stderr);
		stderr = null;
		if (handle != null) release();
	}

	public function kill():Void {
		if (exitCode == null && handle != null) Uv.processKill(handle, SIGKILL);
	}
}

// port: exception Spawn_error
private class SpawnError extends haxe.Exception {}
#else
// port: the port is compiled for other targets (hl, neko) but never run there.
// ... They have no libuv, so a process cannot start; Sys.command without a
// ... directory is the host's.
class EvalProcess {
	function new() {}

	public static function run(cmd:String, args:Null<Array<String>>, ?cwd:String):EvalProcess
		throw new Failure("port: processes need hxmc's libuv");

	public static function command(cmd:String, ?cwd:String):Int {
		if (cwd == null) return Sys.command(cmd);
		throw new Failure("port: processes need hxmc's libuv");
	}

	public function readStdout(buf:Bytes, pos:Int, len:Int):Int throw new Failure("process_stdout_read");

	public function readStderr(buf:Bytes, pos:Int, len:Int):Int throw new Failure("process_stderr_read");

	public function writeStdin(buf:Bytes, pos:Int, len:Int):Int throw new Failure("process_stdin_write");

	public function closeStdin():Void {}

	public function exit():Int return 255;

	public function pid():Int return 0;

	public function close():Void {}

	public function kill():Void {}
}
#end
