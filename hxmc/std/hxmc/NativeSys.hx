package hxmc;

import hxmc.rt.PosixSys;
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.WasiSys;
#end
#if (hxmc.wasm_gc)
import hxmc.rt.gc.GcSys;
#end
import hxmc.rt.WinSys;
import hxmc.unsafe.Mem;

// Operating-system primitives, the base of the std's Sys, sys.io.* and
// sys.FileSystem: POSIX (hxmc.rt.PosixSys) or Windows (hxmc.rt.WinSys), chosen
// by the target (Mem.os folds while lowering: only one is reached), or WASI
// (hxmc.rt.WasiSys) for WebAssembly, a program typed for it (-D
// hxmc.target=wasm32-wasi: its runtime is typed only then).
class NativeSys {
	public static inline function print(s:String):Void {
		#if (hxmc.wasm_gc) GcSys.print(s); #elseif (hxmc.target == "wasm32-wasi") WasiSys.print(s); #else if (Mem.os() == 2) WinSys.print(s) else PosixSys.print(s); #end
	}

	public static inline function printErr(s:String):Void {
		#if (hxmc.wasm_gc) GcSys.printErr(s); #elseif (hxmc.target == "wasm32-wasi") WasiSys.printErr(s); #else if (Mem.os() == 2) WinSys.printErr(s) else PosixSys.printErr(s); #end
	}

	public static inline function args():Array<String>
		return #if (hxmc.wasm_gc) GcSys.args() #elseif (hxmc.target == "wasm32-wasi") WasiSys.args() #else Mem.os() == 2 ? WinSys.args() : PosixSys.args() #end;

	// the program name as invoked (argv[0])
	public static inline function argv0():Null<String>
		return #if (hxmc.wasm_gc) GcSys.argv0() #elseif (hxmc.target == "wasm32-wasi") WasiSys.argv0() #else Mem.os() == 2 ? WinSys.argv0() : PosixSys.argv0() #end;

	public static inline function getEnv(s:String):Null<String>
		return #if (hxmc.wasm_gc) GcSys.getEnv(s) #elseif (hxmc.target == "wasm32-wasi") WasiSys.getEnv(s) #else Mem.os() == 2 ? WinSys.getEnv(s) : PosixSys.getEnv(s) #end;

	public static inline function putEnv(s:String, v:Null<String>):Void {
		#if (hxmc.wasm_gc) GcSys.putEnv(s, v); #elseif (hxmc.target == "wasm32-wasi") WasiSys.putEnv(s, v); #else if (Mem.os() == 2) WinSys.putEnv(s, v) else PosixSys.putEnv(s, v); #end
	}

	// "name=value"
	public static inline function environ():Array<String>
		return #if (hxmc.wasm_gc) GcSys.environ() #elseif (hxmc.target == "wasm32-wasi") WasiSys.environ() #else Mem.os() == 2 ? WinSys.environ() : PosixSys.environ() #end;

	public static inline function sleep(seconds:Float):Void {
		#if (hxmc.wasm_gc) GcSys.sleep(seconds); #elseif (hxmc.target == "wasm32-wasi") WasiSys.sleep(seconds); #else if (Mem.os() == 2) WinSys.sleep(seconds) else PosixSys.sleep(seconds); #end
	}

	public static inline function getCwd():String
		return #if (hxmc.wasm_gc) GcSys.getCwd() #elseif (hxmc.target == "wasm32-wasi") WasiSys.getCwd() #else Mem.os() == 2 ? WinSys.getCwd() : PosixSys.getCwd() #end;

	public static inline function setCwd(s:String):Bool
		return #if (hxmc.wasm_gc) GcSys.setCwd(s) #elseif (hxmc.target == "wasm32-wasi") WasiSys.setCwd(s) #else Mem.os() == 2 ? WinSys.setCwd(s) : PosixSys.setCwd(s) #end;

	public static inline function systemName():String
		return #if (hxmc.wasm_gc) GcSys.systemName() #elseif (hxmc.target == "wasm32-wasi") WasiSys.systemName() #else Mem.os() == 2 ? WinSys.systemName() : PosixSys.systemName() #end;

	// also under Cosmopolitan (whose systemName is "Linux")
	public static inline function hostSystem():String
		return #if (hxmc.wasm_gc) GcSys.hostSystem() #elseif (hxmc.target == "wasm32-wasi") WasiSys.hostSystem() #else Mem.os() == 2 ? WinSys.hostSystem() : PosixSys.hostSystem() #end;

	// through the shell
	public static inline function command(cmd:String):Int
		return #if (hxmc.wasm_gc) GcSys.command(cmd) #elseif (hxmc.target == "wasm32-wasi") WasiSys.command(cmd) #else Mem.os() == 2 ? WinSys.command(cmd) : PosixSys.command(cmd) #end;

	// Windows: without a shell; -2 elsewhere
	public static inline function commandArgs(cmd:String, args:Array<String>):Int
		return #if (hxmc.wasm_gc) GcSys.commandArgs(cmd, args) #elseif (hxmc.target == "wasm32-wasi") WasiSys.commandArgs(cmd, args) #else Mem.os() == 2 ? WinSys.commandArgs(cmd, args) : PosixSys.commandArgs(cmd, args) #end;

	public static inline function exit(code:Int):Void {
		#if (hxmc.wasm_gc) GcSys.exit(code); #elseif (hxmc.target == "wasm32-wasi") WasiSys.exit(code); #else if (Mem.os() == 2) WinSys.exit(code) else PosixSys.exit(code); #end
	}

	public static inline function time():Float
		return #if (hxmc.wasm_gc) GcSys.time() #elseif (hxmc.target == "wasm32-wasi") WasiSys.time() #else Mem.os() == 2 ? WinSys.time() : PosixSys.time() #end;

	public static inline function cpuTime():Float
		return #if (hxmc.wasm_gc) GcSys.cpuTime() #elseif (hxmc.target == "wasm32-wasi") WasiSys.cpuTime() #else Mem.os() == 2 ? WinSys.cpuTime() : PosixSys.cpuTime() #end;

	public static inline function programPath():String
		return #if (hxmc.wasm_gc) GcSys.programPath() #elseif (hxmc.target == "wasm32-wasi") WasiSys.programPath() #else Mem.os() == 2 ? WinSys.programPath() : PosixSys.programPath() #end;

	public static inline function getChar(echo:Bool):Int
		return #if (hxmc.wasm_gc) GcSys.getChar(echo) #elseif (hxmc.target == "wasm32-wasi") WasiSys.getChar(echo) #else Mem.os() == 2 ? WinSys.getChar(echo) : PosixSys.getChar(echo) #end;

	// files: descriptors
	// 0 read, 1 write, 2 append, 3 update; -1 on error
	public static inline function fileOpen(path:String, mode:Int):Int
		return #if (hxmc.wasm_gc) GcSys.fileOpen(path, mode) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileOpen(path, mode) #else Mem.os() == 2 ? WinSys.fileOpen(path, mode) : PosixSys.fileOpen(path, mode) #end;

	// 0 at end, -1 on error
	public static inline function fileRead(fd:Int, b:haxe.io.Bytes, pos:Int, len:Int):Int
		return #if (hxmc.wasm_gc) GcSys.fileRead(fd, b.getData(), pos, len) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileRead(fd, b.getData(), pos, len) #else Mem.os() == 2 ? WinSys.fileRead(fd, b.getData(), pos, len) : PosixSys.fileRead(fd, b.getData(), pos, len) #end;

	public static inline function fileWrite(fd:Int, b:haxe.io.Bytes, pos:Int, len:Int):Int
		return #if (hxmc.wasm_gc) GcSys.fileWrite(fd, b.getData(), pos, len) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileWrite(fd, b.getData(), pos, len) #else Mem.os() == 2 ? WinSys.fileWrite(fd, b.getData(), pos, len) : PosixSys.fileWrite(fd, b.getData(), pos, len) #end;

	// WebAssembly: the buffered standard output written out (elsewhere writes
	// are not buffered)
	public static inline function fileFlush(fd:Int):Void {
		#if (hxmc.wasm_gc) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileFlush(fd); #end
	}

	public static inline function fileClose(fd:Int):Void {
		#if (hxmc.wasm_gc) GcSys.fileClose(fd); #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileClose(fd); #else if (Mem.os() == 2) WinSys.fileClose(fd) else PosixSys.fileClose(fd); #end
	}

	public static inline function fileSeek(fd:Int, p:Int, whence:Int):Void {
		#if (hxmc.wasm_gc) GcSys.fileSeek(fd, p, whence); #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileSeek(fd, p, whence); #else if (Mem.os() == 2) WinSys.fileSeek(fd, p, whence) else PosixSys.fileSeek(fd, p, whence); #end
	}

	public static inline function fileTell(fd:Int):Int
		return #if (hxmc.wasm_gc) GcSys.fileTell(fd) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileTell(fd) #else Mem.os() == 2 ? WinSys.fileTell(fd) : PosixSys.fileTell(fd) #end;

	public static inline function fileContent(path:String):Null<haxe.io.Bytes> {
		// (the runtime's: the BytesData)
		var d:Null<haxe.io.BytesData> = #if (hxmc.wasm_gc) GcSys.fileContent(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileContent(path) #else Mem.os() == 2 ? WinSys.fileContent(path) : PosixSys.fileContent(path) #end;
		return d == null ? null : haxe.io.Bytes.ofData(d);
	}

	public static inline function fileSave(path:String, b:haxe.io.Bytes, append:Bool):Bool
		return #if (hxmc.wasm_gc) GcSys.fileSave(path, b.getData(), append) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fileSave(path, b.getData(), append) #else Mem.os() == 2 ? WinSys.fileSave(path, b.getData(), append) : PosixSys.fileSave(path, b.getData(), append) #end;

	public static inline function exists(path:String):Bool
		return #if (hxmc.wasm_gc) GcSys.exists(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.exists(path) #else Mem.os() == 2 ? WinSys.exists(path) : PosixSys.exists(path) #end;

	public static inline function isDirectory(path:String):Bool
		return #if (hxmc.wasm_gc) GcSys.isDirectory(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.isDirectory(path) #else Mem.os() == 2 ? WinSys.isDirectory(path) : PosixSys.isDirectory(path) #end;

	public static inline function createDirectory(path:String):Bool
		return #if (hxmc.wasm_gc) GcSys.createDirectory(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.createDirectory(path) #else Mem.os() == 2 ? WinSys.createDirectory(path) : PosixSys.createDirectory(path) #end;

	public static inline function deleteFile(path:String):Bool
		return #if (hxmc.wasm_gc) GcSys.deleteFile(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.deleteFile(path) #else Mem.os() == 2 ? WinSys.deleteFile(path) : PosixSys.deleteFile(path) #end;

	public static inline function deleteDirectory(path:String):Bool
		return #if (hxmc.wasm_gc) GcSys.deleteDirectory(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.deleteDirectory(path) #else Mem.os() == 2 ? WinSys.deleteDirectory(path) : PosixSys.deleteDirectory(path) #end;

	public static inline function rename(path:String, newPath:String):Bool
		return #if (hxmc.wasm_gc) GcSys.rename(path, newPath) #elseif (hxmc.target == "wasm32-wasi") WasiSys.rename(path, newPath) #else Mem.os() == 2 ? WinSys.rename(path, newPath) : PosixSys.rename(path, newPath) #end;

	public static inline function readDirectory(path:String):Null<Array<String>>
		return #if (hxmc.wasm_gc) GcSys.readDirectory(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.readDirectory(path) #else Mem.os() == 2 ? WinSys.readDirectory(path) : PosixSys.readDirectory(path) #end;

	// realpath; Windows: GetFullPathName (Extc.get_full_path)
	public static inline function fullPath(path:String):Null<String>
		return #if (hxmc.wasm_gc) GcSys.fullPath(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.fullPath(path) #else Mem.os() == 2 ? WinSys.fullPath(path) : PosixSys.fullPath(path) #end;

	// Extc.get_real_path: Windows' spelling of an existing path; fullPath elsewhere
	public static inline function realPath(path:String):Null<String>
		return #if (hxmc.wasm_gc) GcSys.realPath(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.realPath(path) #else Mem.os() == 2 ? WinSys.realPath(path) : PosixSys.realPath(path) #end;

	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static inline function stat(path:String):Null<Array<Float>>
		return #if (hxmc.wasm_gc) GcSys.stat(path) #elseif (hxmc.target == "wasm32-wasi") WasiSys.stat(path) #else Mem.os() == 2 ? WinSys.stat(path) : PosixSys.stat(path) #end;

	// processes
	// pid, fds: stdin, stdout, stderr
	public static inline function processRun(cmd:String, args:Null<Array<String>>, fds:Array<Int>):Int
		return #if (hxmc.wasm_gc) GcSys.processRun(cmd, args, fds) #elseif (hxmc.target == "wasm32-wasi") WasiSys.processRun(cmd, args, fds) #else Mem.os() == 2 ? WinSys.processRun(cmd, args, fds) : PosixSys.processRun(cmd, args, fds) #end;

	// exit code, -1 while running
	public static inline function processWait(pid:Int, block:Bool):Int
		return #if (hxmc.wasm_gc) GcSys.processWait(pid, block) #elseif (hxmc.target == "wasm32-wasi") WasiSys.processWait(pid, block) #else Mem.os() == 2 ? WinSys.processWait(pid, block) : PosixSys.processWait(pid, block) #end;

	public static inline function processKill(pid:Int):Void {
		#if (hxmc.wasm_gc) GcSys.processKill(pid); #elseif (hxmc.target == "wasm32-wasi") WasiSys.processKill(pid); #else if (Mem.os() == 2) WinSys.processKill(pid) else PosixSys.processKill(pid); #end
	}
}
