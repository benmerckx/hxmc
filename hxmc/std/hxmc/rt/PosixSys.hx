package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;

// The operating-system primitives of hxmc.NativeSys on Linux and macOS
// (formerly rt_sys.c; NativeSys calls them only there). Over the C library (hxmc.unsafe.Posix): its
// constants and structure offsets per target below. Paths and arguments are
// passed as malloc'ed UTF-8 copies (no heap address crosses a call that
// may block). With several threads, reads and waits go through the
// runtime's scheduler (rt_wait_fd, safe regions: Threads.hx).
class PosixSys {
	static inline function mac():Bool
		return Mem.os() == 1;

	// macOS x86-64: the 64-bit-inode variants of stat and readdir (as its headers name them)
	static inline function inode64():Bool
		return Mem.target() == 2;

	static inline function threads():Int
		return Mem.getI32(Mem.sym("rt_nthreads"), 0);

	@:hxmc.noGc static function errno():Int
		return Mem.getI32(mac() ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location(), 0);

	static inline var EINTR = 4;

	// a malloc'ed UTF-8 copy of s
	static inline function cstr(s:String):Ptr
		return Str.toUtf8(s);

	static inline function ofC(p:Ptr):String
		return Str.ofUtf8(p, LibC.strlen(p).toInt());

	@:hxmc.noGc static function writeAll(fd:Int, p:Ptr, n:Int) {
		while (n > 0) {
			var w = Posix.write(fd, p, n).toInt();
			if (w < 0) {
				if (errno() == EINTR) continue;
				return;
			}
			p = p.add(w);
			n -= w;
		}
	}

	static function printTo(fd:Int, s:String) {
		var u = cstr(Str.orNull(s));
		writeAll(fd, u, LibC.strlen(u).toInt());
		LibC.free(u);
	}

	public static function print(s:String):Void
		printTo(1, s);

	public static function printErr(s:String):Void
		printTo(2, s);

	// an Array<String> of n C strings
	static function strArray(v:Ptr, n:Int):Array<String> {
		var a:Array<String> = [];
		for (i in 0...n)
			a.push(ofC(Mem.getPtr(v, 8 * i)));
		return a;
	}

	static inline function argc():Int
		return Mem.getI32(Mem.sym("rt_argc"), 0);

	static inline function argv():Ptr
		return Mem.getPtr(Mem.sym("rt_argv"), 0);

	public static function args():Array<String>
		return strArray(argv().add(8), argc() > 0 ? argc() - 1 : 0);

	public static function argv0():String
		return argc() > 0 ? ofC(Mem.getPtr(argv(), 0)) : null;

	public static function getEnv(s:String):String {
		var n = cstr(s);
		var v = Posix.getenv(n);
		LibC.free(n);
		return v.isNull() ? null : ofC(v);
	}

	public static function putEnv(s:String, v:String):Void {
		var n = cstr(s);
		if (!Str.isNull(v)) {
			var u = cstr(v);
			Posix.setenv(n, u, 1);
			LibC.free(u);
		} else Posix.unsetenv(n);
		LibC.free(n);
	}

	public static function environ():Array<String> {
		var env = mac() ? Mem.getPtr(Posix._NSGetEnviron(), 0) : Mem.target() >= 9 ? Mem.getPtr(Start.environ, 0) : Mem.getPtr(Mem.sym("environ"), 0);
		var n = 0;
		while (!Mem.getPtr(env, 8 * n).isNull())
			n++;
		return strArray(env, n);
	}

	// with other threads, sleeping lets them run (rt_sleep)
	public static function sleep(seconds:Float):Void {
		if (threads() > 1) {
			Rt.rt_sleep(seconds); // 0: give way to the other runnable threads
			return;
		}
		if (seconds <= 0) return;
		var t = Mem.stack(16);
		var s:I64 = cast seconds;
		Mem.setI64(t, 0, s);
		var ns:I64 = cast((seconds - (cast s : Float)) * 1e9);
		Mem.setI64(t, 8, ns);
		while (Posix.nanosleep(t, t) != 0 && errno() == EINTR) {}
	}

	public static function getCwd():String {
		var buf = Mem.stack(4104);
		if (Posix.getcwd(buf, 4096).isNull()) Rt.rt_throw("getCwd failed");
		var n = LibC.strlen(buf).toInt();
		if (n == 0 || Mem.getU8(buf, n - 1) != "/".code) {
			Mem.setI8(buf, n, "/".code);
			Mem.setI8(buf, n + 1, 0);
		}
		return ofC(buf);
	}

	public static function setCwd(s:String):Bool {
		var n = cstr(s);
		var r = Posix.chdir(n);
		LibC.free(n);
		return r == 0;
	}

	public static function systemName():String
		return mac() ? "Mac" : "Linux";

	public static function hostSystem():String
		return systemName();

	// the wait status: exited, killed by a signal, else -1
	static function exitCode(st:Int):Int {
		var sig = st & 0x7f;
		if (sig == 0) return (st >> 8) & 0xff;
		if (sig != 0x7f) return 128 + sig;
		return -1;
	}

	public static function command(cmd:String):Int {
		var c = cstr(cmd);
		Posix.fflush(Ptr.nil());
		Leaf.rt_blocking_enter();
		var r = Posix.system(c); // c is malloc'ed: no heap address
		Leaf.rt_blocking_leave();
		LibC.free(c);
		if (r == -1) return -1;
		return (r & 0x7f) == 0 ? (r >> 8) & 0xff : 128 + (r & 0x7f);
	}

	// Windows runs cmd with args without a shell; here -2: Sys.command quotes
	// them for /bin/sh
	public static function commandArgs(cmd:String, args:Array<String>):Int
		return -2;

	public static function exit(code:Int):Void {
		Posix.fflush(Ptr.nil());
		// (Android: the process ends without the other libraries' destructors,
		// which the system's threads, EGL's among them, may still need)
		if (Mem.target() >= 9) Os.exit(code) else Posix.exit(code);
	}

	@:hxmc.noGc public static function time():Float {
		var tv = Mem.stack(16);
		Posix.gettimeofday(tv, Ptr.nil());
		var s:Float = cast Mem.getI64(tv, 0);
		return s + Mem.getI32(tv, 8) / 1e6;
	}

	// clock() / CLOCKS_PER_SEC (1000000 on Linux and macOS)
	@:hxmc.noGc public static function cpuTime():Float {
		var c:Float = cast Posix.clock();
		return c / 1e6;
	}

	public static function programPath():String {
		var buf = Mem.stack(4104);
		if (mac()) {
			// the executable's path as dyld loaded it (argv[0] may be a bare
			// name found on PATH), then without links
			var path = Mem.stack(4104);
			var size = Mem.stack(8);
			Mem.setI32(size, 0, 4096);
			if (Posix._NSGetExecutablePath(path, size) == 0) {
				var r = Posix.realpathExtsn(path, buf);
				return ofC(r.isNull() ? path : buf);
			}
		}
		var n = Posix.readlink(procSelfExe(), buf, 4096).toInt();
		if (n > 0) {
			Mem.setI8(buf, n, 0);
			return ofC(buf);
		}
		if (argc() > 0) {
			var r = mac() ? Posix.realpathExtsn(Mem.getPtr(argv(), 0), buf) : Posix.realpath(Mem.getPtr(argv(), 0), buf);
			return ofC(r.isNull() ? Mem.getPtr(argv(), 0) : buf);
		}
		return "";
	}

	// "/proc/self/exe" as a C string (a frame area of the caller's would do;
	// this one is static and immortal)
	static var procExe:Ptr;

	@:hxmc.noGc static function procSelfExe():Ptr {
		var p = procExe;
		if (p.isNull()) {
			p = LibC.malloc(16);
			var s = "/proc/self/exe";
			for (i in 0...14)
				Mem.setU8At(p, 0, i, Str.unit(s, i));
			Mem.setI8(p, 14, 0);
			procExe = p;
		}
		return p;
	}

	// struct termios: c_lflag at 12 (4 bytes) on Linux, at 24 (8) on macOS;
	// ICANON 2 / 0x100, ECHO 8 on both; TCSANOW 0
	public static function getChar(echo:Bool):Int {
		var old = Mem.stack(128), raw = Mem.stack(128);
		var tty = Posix.isatty(0) != 0 && Posix.tcgetattr(0, old) == 0;
		if (tty) {
			LibC.memcpy(raw, old, 128);
			var off = mac() ? 24 : 12;
			var flags = (mac() ? 0x100 : 2) | (echo ? 0 : 8);
			Mem.setI32(raw, off, Mem.getI32(raw, off) & ~flags);
			Posix.tcsetattr(0, 0, raw);
		}
		var c = Mem.stack(8);
		if (threads() > 1) Rt.rt_wait_fd(0, 0, -1);
		var r = Posix.read(0, c, 1).toInt();
		if (tty) Posix.tcsetattr(0, 0, old);
		if (r <= 0) Rt.rt_throw("Eof");
		return Mem.getU8(c, 0);
	}

	// ---- files

	// open(2) flags: Linux / macOS
	static inline function oCreat():Int
		return mac() ? 0x200 : 0x40;

	static inline function oTrunc():Int
		return mac() ? 0x400 : 0x200;

	static inline function oAppend():Int
		return mac() ? 0x8 : 0x400;

	static inline function oCloexec():Int
		return mac() ? 0x1000000 : 0x80000;

	public static function fileOpen(path:String, mode:Int):Int {
		var flags = switch mode {
			case 0: 0; // O_RDONLY
			case 1: 1 | oCreat() | oTrunc(); // O_WRONLY
			case 2: 1 | oCreat() | oAppend();
			case 3: 2 | oCreat(); // O_RDWR
			case _: return -1;
		}
		var p = cstr(path);
		var fd = Posix.open(p, flags | oCloexec(), 438); // 0666
		LibC.free(p);
		return fd;
	}

	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	public static function fileRead(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1 && Rt.rt_wait_fd(fd, 0, -1) < 0) return -1; // closed while waiting
		while (true) {
			// (ready: the read does not block, and nothing collects during it)
			var r = Posix.read(fd, Bytes.bytes(b).add(pos), len).toInt();
			if (r < 0 && errno() == EINTR) continue;
			return r;
		}
	}

	public static function fileWrite(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1 && Rt.rt_wait_fd(fd, 1, -1) < 0) return -1;
		while (true) {
			var r = Posix.write(fd, Bytes.bytes(b).add(pos), len).toInt();
			if (r < 0 && errno() == EINTR) continue;
			return r;
		}
	}

	public static function fileClose(fd:Int):Void {
		Leaf.rt_fd_closed(fd);
		Posix.close(fd);
	}

	public static function fileSeek(fd:Int, p:Int, whence:Int):Void {
		if (Posix.lseek(fd, p, whence < 0 || whence > 2 ? 0 : whence) < 0) Rt.rt_throw("seek failed");
	}

	@:hxmc.noGc public static function fileTell(fd:Int):Int
		return Posix.lseek(fd, 0, 1).toInt();

	// struct stat: st_mode, st_size (and the rest for stat()) per target
	static inline function statSize():Int
		return 144;

	static inline function stMode(st:Ptr):Int
		return mac() ? Mem.getU16(st, 4) : Mem.arm() ? Mem.getI32(st, 16) : Mem.getI32(st, 24);

	static inline function stSize(st:Ptr):I64
		return mac() ? Mem.getI64(st, 96) : Mem.getI64(st, 48);

	@:hxmc.noGc static function doStat(p:Ptr, st:Ptr):Int
		return inode64() ? Posix.statInode64(p, st) : Posix.stat(p, st);

	@:hxmc.noGc static function doFstat(fd:Int, st:Ptr):Int
		return inode64() ? Posix.fstatInode64(fd, st) : Posix.fstat(fd, st);

	static inline function isReg(mode:Int):Bool
		return (mode & 0xF000) == 0x8000;

	static inline function isDir(mode:Int):Bool
		return (mode & 0xF000) == 0x4000;

	public static function fileContent(path:String):Dynamic {
		var p = cstr(path);
		var fd = Posix.open(p, oCloexec(), 0);
		LibC.free(p);
		if (fd < 0) return null;
		// read into malloc'ed memory first: the size may not be known (pipes)
		var cap = 65536, n = 0;
		var st = Mem.stack(256);
		if (doFstat(fd, st) == 0 && isReg(stMode(st))) cap = stSize(st).toInt() + 1;
		var buf = LibC.malloc(cap);
		while (true) {
			if (n == cap) {
				cap *= 2;
				buf = LibC.realloc(buf, cap);
			}
			var r = Posix.read(fd, buf.add(n), cap - n).toInt();
			if (r < 0 && errno() == EINTR) continue;
			if (r < 0) {
				LibC.free(buf);
				Posix.close(fd);
				return null;
			}
			if (r == 0) break;
			n += r;
		}
		Posix.close(fd);
		var b = Bytes.alloc(n);
		LibC.memcpy(Bytes.bytes(b), buf, n);
		LibC.free(buf);
		return b;
	}

	public static function fileSave(path:String, b:Dynamic, append:Bool):Bool {
		var p = cstr(path);
		var fd = Posix.open(p, 1 | oCreat() | oCloexec() | (append ? oAppend() : oTrunc()), 438);
		LibC.free(p);
		if (fd < 0) return false;
		return saveAll(fd, Bytes.bytes(b), Bytes.len(b));
	}

	@:hxmc.noGc static function saveAll(fd:Int, d:Ptr, n:Int):Bool {
		var ok = true;
		while (n > 0) {
			var w = Posix.write(fd, d, n).toInt();
			if (w < 0) {
				if (errno() == EINTR) continue;
				ok = false;
				break;
			}
			d = d.add(w);
			n -= w;
		}
		return Posix.close(fd) == 0 && ok;
	}

	public static function exists(path:String):Bool {
		var p = cstr(path);
		var st = Mem.stack(256);
		var r = doStat(p, st) == 0;
		LibC.free(p);
		return r;
	}

	public static function isDirectory(path:String):Bool {
		var p = cstr(path);
		var st = Mem.stack(256);
		var r = doStat(p, st) == 0 && isDir(stMode(st));
		LibC.free(p);
		return r;
	}

	public static function createDirectory(path:String):Bool {
		var p = cstr(path);
		var r = Posix.mkdir(p, 511) == 0; // 0777
		LibC.free(p);
		return r;
	}

	public static function deleteFile(path:String):Bool {
		var p = cstr(path);
		var r = Posix.unlink(p) == 0;
		LibC.free(p);
		return r;
	}

	public static function deleteDirectory(path:String):Bool {
		var p = cstr(path);
		var r = Posix.rmdir(p) == 0;
		LibC.free(p);
		return r;
	}

	public static function rename(path:String, newPath:String):Bool {
		var a = cstr(path), b = cstr(newPath);
		var r = Posix.rename(a, b) == 0;
		LibC.free(a);
		LibC.free(b);
		return r;
	}

	// struct dirent: d_name at 19 (Linux), 21 (macOS, 64-bit inodes)
	public static function readDirectory(path:String):Array<String> {
		var p = cstr(path);
		var d = inode64() ? Posix.opendirInode64(p) : Posix.opendir(p);
		LibC.free(p);
		if (d.isNull()) return null;
		var names:Array<String> = [];
		var off = mac() ? 21 : 19;
		while (true) {
			var e = inode64() ? Posix.readdirInode64(d) : Posix.readdir(d);
			if (e.isNull()) break;
			var n = e.add(off);
			if (Mem.getU8(n, 0) == ".".code && (Mem.getU8(n, 1) == 0 || (Mem.getU8(n, 1) == ".".code && Mem.getU8(n, 2) == 0))) continue;
			names.push(ofC(n)); // (the directory stream is outside the heap)
		}
		Posix.closedir(d);
		return names;
	}

	public static function fullPath(path:String):String {
		var p = cstr(path);
		var buf = Mem.stack(4104);
		var r = mac() ? Posix.realpathExtsn(p, buf) : Posix.realpath(p, buf);
		LibC.free(p);
		return r.isNull() ? null : ofC(buf);
	}

	// Extc.get_real_path is get_full_path outside Windows
	public static function realPath(path:String):String
		return fullPath(path);

	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static function stat(path:String):Array<Float> {
		var p = cstr(path);
		var st = Mem.stack(256);
		var r = doStat(p, st);
		LibC.free(p);
		if (r != 0) return null;
		inline function f(v:I64):Float
			return cast v;
		inline function u(v:Int):Float
			return f((v : I64) & (((1 : I64) << 32) - 1));
		if (mac())
			return [
				u(Mem.getI32(st, 20)), u(Mem.getI32(st, 16)), f(Mem.getI64(st, 32)), f(Mem.getI64(st, 48)), f(Mem.getI64(st, 64)), u(Mem.getI32(st, 0)),
				f(Mem.getI64(st, 8)), Mem.getU16(st, 6), u(Mem.getI32(st, 24)), f(Mem.getI64(st, 96)), Mem.getU16(st, 4)
			];
		if (Mem.arm())
			return [
				u(Mem.getI32(st, 28)), u(Mem.getI32(st, 24)), f(Mem.getI64(st, 72)), f(Mem.getI64(st, 88)), f(Mem.getI64(st, 104)), f(Mem.getI64(st, 0)),
				f(Mem.getI64(st, 8)), u(Mem.getI32(st, 20)), f(Mem.getI64(st, 32)), f(Mem.getI64(st, 48)), u(Mem.getI32(st, 16))
			];
		return [
			u(Mem.getI32(st, 32)), u(Mem.getI32(st, 28)), f(Mem.getI64(st, 72)), f(Mem.getI64(st, 88)), f(Mem.getI64(st, 104)), f(Mem.getI64(st, 0)),
			f(Mem.getI64(st, 8)), f(Mem.getI64(st, 16)), f(Mem.getI64(st, 40)), f(Mem.getI64(st, 48)), u(Mem.getI32(st, 24))
		];
	}

	// ---- processes

	public static function processRun(cmd:String, args:Array<String>, fds:Array<Int>):Int {
		// argv in malloc'ed C strings before forking
		var n = Str.isNull(args) ? 0 : args.length;
		var argv = LibC.malloc(8 * (n + 4));
		if (!Str.isNull(args)) {
			Mem.setPtr(argv, 0, cstr(cmd));
			for (i in 0...n)
				Mem.setPtr(argv, 8 * (i + 1), cstr(args[i]));
			Mem.setPtr(argv, 8 * (n + 1), Ptr.nil());
		} else {
			Mem.setPtr(argv, 0, Str.toUtf8("/bin/sh"));
			Mem.setPtr(argv, 8, Str.toUtf8("-c"));
			Mem.setPtr(argv, 16, cstr(cmd));
			Mem.setPtr(argv, 24, Ptr.nil());
			n = 2;
		}
		var p = Mem.stack(32);
		var pid = pipes(p) ? spawn(argv, p) : -2;
		for (i in 0...n + 1)
			LibC.free(Mem.getPtr(argv, 8 * i));
		LibC.free(argv);
		if (pid == -2) Rt.rt_throw("Process creation failure");
		if (pid < 0) {
			Posix.close(Mem.getI32(p, 4));
			Posix.close(Mem.getI32(p, 8));
			Posix.close(Mem.getI32(p, 16));
			Rt.rt_throw("Process creation failure");
		}
		fds[0] = Mem.getI32(p, 4);
		fds[1] = Mem.getI32(p, 8);
		fds[2] = Mem.getI32(p, 16);
		return pid;
	}

	// The three pipes (p: in[2], out[2], err[2]), close-on-exec from the start
	// (upstream's Unix.pipe ~cloexec:true): a process another thread starts
	// meanwhile must not inherit them (it would hold their ends open). pipe2
	// on Linux; macOS has no pipe2: pipe, then FD_CLOEXEC under the
	// descriptor lock, which fork takes too (spawn). False: a failure, with
	// nothing left open.
	@:hxmc.noGc static function pipes(p:Ptr):Bool {
		if (!mac()) {
			for (k in 0...3)
				if (Posix.pipe2(p.add(8 * k), oCloexec()) != 0) {
					closeFds(p, 2 * k);
					return false;
				}
			return true;
		}
		Threads.lockSafe(Gc.fdLock);
		var k = 0;
		while (k < 3 && Posix.pipe(p.add(8 * k)) == 0)
			k++;
		for (i in 0...2 * k)
			Posix.fcntl(Mem.getI32(p, 4 * i), 2, 1); // F_SETFD, FD_CLOEXEC
		Os.unlock(Gc.fdLock);
		if (k == 3) return true;
		closeFds(p, 2 * k);
		return false;
	}

	@:hxmc.noGc static function closeFds(p:Ptr, n:Int)
		for (i in 0...n)
			Posix.close(Mem.getI32(p, 4 * i));

	// macOS: fd, a descriptor just created, close-on-exec; the caller holds
	// the descriptor lock (see pipes)
	@:hxmc.noGc public static function cloexec(fd:Int):Int {
		if (fd >= 0) Posix.fcntl(fd, 2, 1); // F_SETFD, FD_CLOEXEC
		return fd;
	}

	// fork and exec with the three pipes, all close-on-exec: the child's ends
	// become 0, 1 and 2 by dup2, which clears the flag, and exec closes the
	// rest; the child calls only the C library
	@:hxmc.noGc static function spawn(argv:Ptr, p:Ptr):Int {
		Posix.fflush(Ptr.nil());
		if (mac()) Threads.lockSafe(Gc.fdLock);
		var pid = Posix.fork();
		if (pid == 0) {
			for (k in 0...3) {
				var fd = Mem.getI32(p, k == 0 ? 0 : 8 * k + 4);
				// (dup2 of a descriptor onto itself keeps the flag)
				if (fd == k) Posix.fcntl(k, 2, 0) else Posix.dup2(fd, k);
			}
			Posix.execvp(Mem.getPtr(argv, 0), argv);
			Posix._exit(127);
		}
		if (mac()) Os.unlock(Gc.fdLock);
		Posix.close(Mem.getI32(p, 0));
		Posix.close(Mem.getI32(p, 12));
		Posix.close(Mem.getI32(p, 20));
		return pid;
	}

	// OS threads: waits in a safe region; WNOHANG 1
	public static function processWait(pid:Int, block:Bool):Int {
		var st = Mem.stack(8);
		while (true) {
			Leaf.rt_blocking_enter();
			var r = Posix.waitpid(pid, st, block ? 0 : 1);
			Leaf.rt_blocking_leave();
			if (r < 0 && errno() == EINTR) continue;
			if (r <= 0) return -1;
			break;
		}
		return exitCode(Mem.getI32(st, 0));
	}

	@:hxmc.noGc public static function processKill(pid:Int):Void
		Posix.kill(pid, 9);
}
