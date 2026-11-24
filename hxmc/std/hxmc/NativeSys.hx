package hxmc;

import hxmc.rt.PosixSys;
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.WasiSys;
#end
#if (!hxmc.os || hxmc.os == "windows")
import hxmc.rt.WinSys;
#end
import hxmc.unsafe.Mem;

// Operating-system primitives, the base of the std's Sys, sys.io.* and
// sys.FileSystem: POSIX (hxmc.rt.PosixSys) or Windows (hxmc.rt.WinSys), chosen
// by the target (Mem.os folds while lowering: only one is reached), or WASI
// (hxmc.rt.WasiSys) for WebAssembly, a program typed for it (-D
// hxmc.target=wasm32-wasi: its runtime is typed only then).
class NativeSys {
	public static inline function print(s:String):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.print(s); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.print(s) else #end PosixSys.print(s); #end
	}

	public static inline function printErr(s:String):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.printErr(s); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.printErr(s) else #end PosixSys.printErr(s); #end
	}

	public static inline function args():Array<String>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.args() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.args() : #end PosixSys.args() #end;

	// the program name as invoked (argv[0])
	public static inline function argv0():Null<String>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.argv0() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.argv0() : #end PosixSys.argv0() #end;

	public static inline function getEnv(s:String):Null<String>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.getEnv(s) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.getEnv(s) : #end PosixSys.getEnv(s) #end;

	public static inline function putEnv(s:String, v:Null<String>):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.putEnv(s, v); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.putEnv(s, v) else #end PosixSys.putEnv(s, v); #end
	}

	// "name=value"
	public static inline function environ():Array<String>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.environ() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.environ() : #end PosixSys.environ() #end;

	public static inline function sleep(seconds:Float):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.sleep(seconds); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.sleep(seconds) else #end PosixSys.sleep(seconds); #end
	}

	public static inline function getCwd():String
		return #if (hxmc.target == "wasm32-wasi") WasiSys.getCwd() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.getCwd() : #end PosixSys.getCwd() #end;

	public static inline function setCwd(s:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.setCwd(s) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.setCwd(s) : #end PosixSys.setCwd(s) #end;

	public static inline function systemName():String
		return #if (hxmc.target == "wasm32-wasi") WasiSys.systemName() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.systemName() : #end PosixSys.systemName() #end;

	// also under Cosmopolitan (whose systemName is "Linux")
	public static inline function hostSystem():String
		return #if (hxmc.target == "wasm32-wasi") WasiSys.hostSystem() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.hostSystem() : #end PosixSys.hostSystem() #end;

	// through the shell
	public static inline function command(cmd:String):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.command(cmd) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.command(cmd) : #end PosixSys.command(cmd) #end;

	// as command, but a command a signal ended gives 256 + the signal (Windows
	// has no signals: as command)
	public static inline function commandStatus(cmd:String):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.command(cmd) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.command(cmd) : #end PosixSys.commandStatus(cmd) #end;

	// Windows: without a shell; -2 elsewhere
	public static inline function commandArgs(cmd:String, args:Array<String>):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.commandArgs(cmd, args) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.commandArgs(cmd, args) : #end PosixSys.commandArgs(cmd, args) #end;

	public static inline function exit(code:Int):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.exit(code); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.exit(code) else #end PosixSys.exit(code); #end
	}

	public static inline function time():Float
		return #if (hxmc.target == "wasm32-wasi") WasiSys.time() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.time() : #end PosixSys.time() #end;

	public static inline function cpuTime():Float
		return #if (hxmc.target == "wasm32-wasi") WasiSys.cpuTime() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.cpuTime() : #end PosixSys.cpuTime() #end;

	public static inline function programPath():String
		return #if (hxmc.target == "wasm32-wasi") WasiSys.programPath() #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.programPath() : #end PosixSys.programPath() #end;

	public static inline function getChar(echo:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.getChar(echo) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.getChar(echo) : #end PosixSys.getChar(echo) #end;

	// files: descriptors
	// 0 read, 1 write, 2 append, 3 update; -1 on error
	public static inline function fileOpen(path:String, mode:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fileOpen(path, mode) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileOpen(path, mode) : #end PosixSys.fileOpen(path, mode) #end;

	// fileRead and fileWrite of a non-blocking descriptor that is not ready
	// (EAGAIN; Windows: reads of a PIPE_NOWAIT pipe), distinct from an error
	public static inline var WOULD_BLOCK = -2;

	// a descriptor non-blocking or blocking again (O_NONBLOCK; Windows: pipes
	// only, PIPE_NOWAIT); false on failure
	public static inline function fileSetBlocking(fd:Int, blocking:Bool):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fileSetBlocking(fd, blocking) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileSetBlocking(fd, blocking) : #end PosixSys.fileSetBlocking(fd, blocking) #end;

	// 0 at end, -1 on error, WOULD_BLOCK
	public static inline function fileRead(fd:Int, b:haxe.io.Bytes, pos:Int, len:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fileRead(fd, b.getData(), pos, len) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileRead(fd, b.getData(), pos, len) : #end PosixSys.fileRead(fd, b, pos, len) #end;

	// -1 on error, WOULD_BLOCK (not on Windows: there a full PIPE_NOWAIT pipe takes what fits)
	public static inline function fileWrite(fd:Int, b:haxe.io.Bytes, pos:Int, len:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fileWrite(fd, b.getData(), pos, len) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileWrite(fd, b.getData(), pos, len) : #end PosixSys.fileWrite(fd, b, pos, len) #end;

	// WebAssembly: the buffered standard output written out (elsewhere writes
	// are not buffered)
	public static inline function fileFlush(fd:Int):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.fileFlush(fd); #end
	}

	public static inline function fileClose(fd:Int):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.fileClose(fd); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.fileClose(fd) else #end PosixSys.fileClose(fd); #end
	}

	public static inline function fileSeek(fd:Int, p:Int, whence:Int):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.fileSeek(fd, p, whence); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.fileSeek(fd, p, whence) else #end PosixSys.fileSeek(fd, p, whence); #end
	}

	public static inline function fileTell(fd:Int):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fileTell(fd) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileTell(fd) : #end PosixSys.fileTell(fd) #end;

	public static inline function fileContent(path:String):Null<haxe.io.Bytes> {
		// (the runtime's: the BytesData)
		var d:Null<haxe.io.BytesData> = #if (hxmc.target == "wasm32-wasi") WasiSys.fileContent(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileContent(path) : #end PosixSys.fileContent(path) #end;
		return d == null ? null : haxe.io.Bytes.ofData(d);
	}

	public static inline function fileSave(path:String, b:haxe.io.Bytes, append:Bool):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fileSave(path, b.getData(), append) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fileSave(path, b.getData(), append) : #end PosixSys.fileSave(path, b.getData(), append) #end;

	public static inline function exists(path:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.exists(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.exists(path) : #end PosixSys.exists(path) #end;

	public static inline function isDirectory(path:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.isDirectory(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.isDirectory(path) : #end PosixSys.isDirectory(path) #end;

	public static inline function createDirectory(path:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.createDirectory(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.createDirectory(path) : #end PosixSys.createDirectory(path) #end;

	public static inline function deleteFile(path:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.deleteFile(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.deleteFile(path) : #end PosixSys.deleteFile(path) #end;

	public static inline function deleteDirectory(path:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.deleteDirectory(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.deleteDirectory(path) : #end PosixSys.deleteDirectory(path) #end;

	public static inline function rename(path:String, newPath:String):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.rename(path, newPath) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.rename(path, newPath) : #end PosixSys.rename(path, newPath) #end;

	public static inline function readDirectory(path:String):Null<Array<String>>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.readDirectory(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.readDirectory(path) : #end PosixSys.readDirectory(path) #end;

	// realpath; Windows: GetFullPathName (Extc.get_full_path)
	public static inline function fullPath(path:String):Null<String>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.fullPath(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.fullPath(path) : #end PosixSys.fullPath(path) #end;

	// Extc.get_real_path: Windows' spelling of an existing path; fullPath elsewhere
	public static inline function realPath(path:String):Null<String>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.realPath(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.realPath(path) : #end PosixSys.realPath(path) #end;

	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static inline function stat(path:String):Null<Array<Float>>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.stat(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.stat(path) : #end PosixSys.stat(path) #end;

	// atime, mtime, ctime to the nanosecond: seconds since the epoch (stat's)
	// and nanoseconds, each a whole Float, then the size: [atime s, ns, mtime
	// s, ns, ctime s, ns, size]; null when the path cannot be stat'ed. Windows: 100 ns units, ctime
	// the creation time (as stat's)
	public static inline function statTimes(path:String):Null<Array<Float>>
		return #if (hxmc.target == "wasm32-wasi") WasiSys.statTimes(path) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.statTimes(path) : #end PosixSys.statTimes(path) #end;

	// processes
	// pid, fds: stdin, stdout, stderr. args null: cmd through the shell. cwd:
	// the child's working directory (null: this process's; one that cannot be
	// entered: no process). env: the child's whole environment, which replaces
	// this process's (null: inherit it; environment() is a copy to change);
	// the program is looked up on its PATH (Windows: on this process's)
	public static inline function processRun(cmd:String, args:Null<Array<String>>, fds:Array<Int>, ?cwd:String, ?env:Map<String, String>):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.processRun(cmd, args, fds, cwd, envList(env)) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.processRun(cmd, args, fds, cwd, envList(env)) : #end PosixSys.processRun(cmd, args, fds, cwd, envList(env)) #end;

	// a copy of this process's environment, for processRun (Windows: with its
	// "=C:" entries, the drives' working directories, which Sys.environment skips)
	public static function environment():Map<String, String> {
		var m = new Map<String, String>();
		for (kv in environ()) {
			var i = kv.indexOf("=", 1);
			if (i > 0) m.set(kv.substr(0, i), kv.substr(i + 1));
		}
		return m;
	}

	// "name=value", sorted by name (Windows wants its environment blocks so)
	static function envList(env:Null<Map<String, String>>):Null<Array<String>> {
		if (env == null) return null;
		var names = [for (k in env.keys()) k];
		names.sort((a, b) -> {
			var x = a.toUpperCase(), y = b.toUpperCase();
			return x < y ? -1 : x > y ? 1 : 0;
		});
		return [for (k in names) k + "=" + env.get(k)];
	}

	// exit code, -1 while running
	public static inline function processWait(pid:Int, block:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.processWait(pid, block) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.processWait(pid, block) : #end PosixSys.processWait(pid, block) #end;

	// as processWait, but a process a signal ended gives 256 + the signal
	// (Windows has no signals: its exit code, as processWait)
	public static inline function processWaitStatus(pid:Int, block:Bool):Int
		return #if (hxmc.target == "wasm32-wasi") WasiSys.processWait(pid, block) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.processWait(pid, block) : #end PosixSys.processWaitStatus(pid, block) #end;

	// SIGINT and SIGQUIT ignored while waiting for a child, as system() does,
	// until as many calls with false (nothing on Windows and WebAssembly)
	public static inline function interruptsIgnored(ignore:Bool):Void {
		#if (hxmc.target != "wasm32-wasi") #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() != 2) #end PosixSys.interruptsIgnored(ignore); #end
	}

	// SIGKILL (Windows: TerminateProcess with exit code 0, as upstream's Unix.kill)
	public static inline function processKill(pid:Int):Void {
		#if (hxmc.target == "wasm32-wasi") WasiSys.processKill(pid); #else #if (!hxmc.os || hxmc.os == "windows") if (Platform.os() == 2) WinSys.processKill(pid) else #end PosixSys.processKill(pid); #end
	}

	// a descriptor that becomes readable when the process exits, to poll with
	// others instead of calling processWait(pid, false) every round (the
	// process is still reaped by processWait; close it with fileClose):
	// Linux's pidfd (pidfd_open, kernel 5.3), close-on-exec. -1 elsewhere
	// (macOS: kqueue's EVFILT_PROC; Windows: the process handle; neither is
	// exposed yet), on an older kernel, or when the process is gone
	public static inline function processExitFd(pid:Int):Int
		return #if (hxmc.target == "wasm32-wasi") -1 #else Platform.os() == 0 ? PosixSys.processExitFd(pid) : -1 #end;

	// signals for processSignal (the same numbers on Linux and macOS)
	public static inline var SIGINT = 2;
	public static inline var SIGKILL = 9;
	public static inline var SIGTERM = 15;

	// sends signal sig to a process this process started; false when there is
	// none (reaped already). Windows: any signal is TerminateProcess with exit
	// code 128 + sig, the code a POSIX process killed by it reports (SIGINT
	// included: a console's Ctrl+C reaches a whole console, not one process)
	public static inline function processSignal(pid:Int, sig:Int):Bool
		return #if (hxmc.target == "wasm32-wasi") WasiSys.processSignal(pid, sig) #else #if (!hxmc.os || hxmc.os == "windows") Platform.os() == 2 ? WinSys.processSignal(pid, sig) : #end PosixSys.processSignal(pid, sig) #end;
}
