package hxmc.rt.gc;

// -D hxmc.wasm-gc: the system functions (hxmc.NativeSys: WasiSys's API), over
// the host (hxmc/bootstrap/wasmgc.mjs, node's: files, their descriptors,
// processes, the shell), the rest (Sys.getChar) an error that says so
@:keep @:hxmc.wasmgc
class GcSys {
	static function unsupported(what:String):Dynamic
		throw what + ": not supported by -D hxmc.wasm-gc";

	// the host's strings joined by "\x00"
	static function list(s:String):Array<String>
		return s == null ? [] : s == "" ? [] : s.split("\x00");

	public static function print(s:String):Void
		W.write(1, s);

	public static function printErr(s:String):Void
		W.write(2, s);

	public static function args():Array<String>
		return list(W.sysStr(4, null, null));

	public static function argv0():String
		return W.sysStr(6, null, null);

	public static function getEnv(s:String):String
		return W.sysStr(0, s, null);

	public static function putEnv(s:String, v:String):Void
		W.sysNum(11, s, v, 0);

	public static function environ():Array<String>
		return list(W.sysStr(5, null, null));

	public static function sleep(seconds:Float):Void
		W.sysNum(10, null, null, seconds);

	public static function getCwd():String
		return W.sysStr(1, null, null);

	public static function setCwd(s:String):Bool
		return W.sysNum(6, s, null, 0) != 0;

	public static function systemName():String
		return W.sysStr(8, null, null);

	public static function hostSystem():String
		return W.sysStr(8, null, null);

	// (through the shell, the standard streams inherited)
	public static function command(cmd:String):Int
		return Std.int(W.sysNum(12, cmd, null, 0));

	// -2: Sys.command quotes the arguments for the shell (as PosixSys)
	public static function commandArgs(cmd:String, args:Array<String>):Int
		return -2;

	public static function exit(code:Int):Void
		W.sysNum(7, null, null, code);

	public static function time():Float
		return W.sysNum(8, null, null, 0);

	public static function cpuTime():Float
		return W.sysNum(9, null, null, 0);

	public static function programPath():String
		return W.sysStr(6, null, null);

	public static function getChar(echo:Bool):Int
		return unsupported("Sys.getChar");

	// files: the host's descriptors (W.fileIo: 0 open, 1 read, 2 write, 3
	// close, 4 seek, 5 tell), written unbuffered

	public static function fileOpen(path:String, mode:Int):Int
		return W.fileIo(0, 0, path, mode, 0);

	static function outside():Void
		throw haxe.io.Error.OutsideBounds;

	public static function fileRead(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > W.bytesLen(b)) outside();
		return W.fileIo(1, fd, b, pos, len);
	}

	public static function fileWrite(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > W.bytesLen(b)) outside();
		return W.fileIo(2, fd, b, pos, len);
	}

	public static function fileFlush(fd:Int):Void {}

	public static function fileClose(fd:Int):Void
		W.fileIo(3, fd, null, 0, 0);

	public static function fileSeek(fd:Int, p:Int, whence:Int):Void
		if (W.fileIo(4, fd, null, p, whence < 0 || whence > 2 ? 0 : whence) < 0) throw "seek failed";

	public static function fileTell(fd:Int):Int
		return W.fileIo(5, fd, null, 0, 0);

	public static function fileContent(path:String):Dynamic
		return W.readFile(path);

	public static function fileSave(path:String, b:Dynamic, append:Bool):Bool
		return W.writeFile(path, b, append);

	public static function exists(path:String):Bool
		return W.sysNum(0, path, null, 0) != 0;

	public static function isDirectory(path:String):Bool
		return W.sysNum(1, path, null, 0) != 0;

	public static function createDirectory(path:String):Bool
		return W.sysNum(2, path, null, 0) != 0;

	public static function deleteFile(path:String):Bool
		return W.sysNum(3, path, null, 0) != 0;

	public static function deleteDirectory(path:String):Bool
		return W.sysNum(4, path, null, 0) != 0;

	public static function rename(path:String, newPath:String):Bool
		return W.sysNum(5, path, newPath, 0) != 0;

	public static function readDirectory(path:String):Array<String> {
		var s = W.sysStr(3, path, null);
		return s == null ? null : list(s);
	}

	public static function fullPath(path:String):String
		return W.sysStr(2, path, null);

	public static function realPath(path:String):String
		return W.sysStr(2, path, null);

	// gid, uid, atime, mtime, ctime, size, dev, ino, nlink, rdev, mode (sys.FileStat's order, as WasiSys)
	public static function stat(path:String):Array<Float> {
		var s = W.sysStr(7, path, null);
		return s == null ? null : [for (x in list(s)) Std.parseFloat(x)];
	}

	// processes: the host's (W.fileIo: 6 run, 7 wait, 8 kill), their standard
	// streams the descriptors PROC_FD + 4 * pid + 0, 1, 2; a command that cannot
	// be run exits 127, as a child whose exec fails (PosixSys)
	static inline var PROC_FD = 0x40000000;

	public static function processRun(cmd:String, args:Array<String>, fds:Array<Int>):Int {
		var pid = W.fileIo(6, 0, args == null ? cmd : [cmd].concat(args).join("\x00"), args == null ? 0 : 1, 0);
		if (pid < 0) return -1;
		for (k in 0...3)
			fds[k] = PROC_FD + 4 * pid + k;
		return pid;
	}

	public static function processWait(pid:Int, block:Bool):Int
		return W.fileIo(7, pid, null, block ? 1 : 0, 0);

	public static function processKill(pid:Int):Void
		W.fileIo(8, pid, null, 0, 0);
}
