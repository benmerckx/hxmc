package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.scoped.Fixed;
import hxmc.scoped.LE;
import hxmc.scoped.Ref;
import hxmc.scoped.Scope;
import hxmc.scoped.Slice;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Posix;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// The operating-system primitives of hxmc.NativeSys on Linux and macOS
// (formerly rt_sys.c; NativeSys calls them only there). Over the C library
// (hxmc.unsafe.Posix), whose calls take views of scoped memory
// (docs/plans/lowlevel.md, "The scoped C boundary"): paths and arguments
// as UTF-8 on the data stack, the structures the system fills in Fixed
// buffers of the frame read little-endian (hxmc.scoped.LE; their offsets per
// target below), no heap address crossing a call that may block. With
// several threads, reads and waits go through the runtime's scheduler
// (rt_wait_fd, safe regions: Threads.hx).
class PosixSys {
	static inline function mac():Bool
		return Mem.os() == 1;

	// macOS x86-64: the 64-bit-inode variants of stat and readdir (as its headers name them)
	static inline function inode64():Bool
		return Mem.target() == 2;

	static inline function threads():Int
		return Mem.getI32(Mem.sym("rt_nthreads"), 0);

	@:hxmc.scoped static function errno():Int
		return (mac() ? Posix.__error() : Mem.target() >= 9 ? Posix.__errno() : Posix.__errno_location()).value;

	static inline var EINTR = 4;

	// s as a C string, on the data stack (SysCore.cref)
	static inline function cstr(s:String):Ref<UInt8>
		return SysCore.cref(s);

	static inline function ofC(r:Ref<UInt8>, off = 0):String
		return SysCore.ofC(r, off);

	@:hxmc.scoped static function writeAll(fd:Int, s:Slice<UInt8>) {
		var p = 0;
		while (p < s.length) {
			var w = Posix.write(fd, s.sub(p, s.length - p)).toInt();
			if (w < 0) {
				if (errno() == EINTR) continue;
				return;
			}
			p += w;
		}
	}

	static function printTo(fd:Int, s:String)
		SysCore.printTo(fd, s);

	public static function print(s:String):Void
		printTo(1, s);

	public static function printErr(s:String):Void
		printTo(2, s);

	// an Array<String> of n C strings
	static function strArray(v:Ptr, n:Int):Array<String> {
		var a:Array<String> = [];
		for (i in 0...n)
			a.push(ofC(Ref.raw(Mem.getPtr(v, 8 * i))));
		return a;
	}

	static inline function argc():Int
		return Mem.getI32(Mem.sym("rt_argc"), 0);

	static inline function argv():Ptr
		return Mem.getPtr(Mem.sym("rt_argv"), 0);

	public static function args():Array<String>
		return strArray(argv().add(8), argc() > 0 ? argc() - 1 : 0);

	public static function argv0():String
		return argc() > 0 ? ofC(Ref.raw(Mem.getPtr(argv(), 0))) : null;

	public static function getEnv(s:String):String
		return ofC(Posix.getenv(cstr(s)));

	public static function putEnv(s:String, v:String):Void {
		var n = cstr(s);
		if (!Str.isNull(v)) Posix.setenv(n, cstr(v), 1) else Posix.unsetenv(n);
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
		if (seconds > 0) nap(seconds);
	}

	// struct timespec: seconds, nanoseconds
	@:hxmc.scoped static function nap(seconds:Float) {
		var t:Fixed<UInt8, 16> = Fixed.scratch(); // (written before the call)
		var v = t.view();
		var s:I64 = cast seconds;
		LE.put64(v, 0, s);
		LE.put64(v, 8, cast((seconds - (cast s : Float)) * 1e9));
		while (Posix.nanosleep(v.ref(0), v.ref(0)) != 0 && errno() == EINTR) {}
	}

	public static function getCwd():String {
		var buf:Slice<UInt8> = Scope.slice(4104);
		if (Posix.getcwd(buf.sub(0, 4096)).isNull()) Rt.rt_throw("getCwd failed");
		var n = Posix.strnlen(buf).toInt();
		if (n == 0 || buf[n - 1] != "/".code) {
			buf[n] = "/".code;
			buf[n + 1] = 0;
		}
		return ofC(buf.ref(0));
	}

	public static function setCwd(s:String):Bool
		return Posix.chdir(cstr(s)) == 0;

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
		var r = Posix.system(c); // (c is on the data stack: no heap address)
		Leaf.rt_blocking_leave();
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

	// struct timeval: seconds, microseconds
	@:hxmc.scoped public static function time():Float {
		var tv:Fixed<UInt8, 16> = Fixed.scratch(); // (C fills it)
		var v = tv.view();
		Posix.gettimeofday(v.ref(0), Ref.nil());
		var s:Float = cast LE.i64(v, 0);
		return s + LE.i32(v, 8) / 1e6;
	}

	// clock() / CLOCKS_PER_SEC (1000000 on Linux and macOS)
	@:hxmc.scoped public static function cpuTime():Float {
		var c:Float = cast Posix.clock();
		return c / 1e6;
	}

	public static function programPath():String {
		var buf:Slice<UInt8> = Scope.slice(4104);
		if (mac()) {
			// the executable's path as dyld loaded it (argv[0] may be a bare
			// name found on PATH), then without links
			var path:Slice<UInt8> = Scope.slice(4104);
			var size = new Fixed<Int, 1>();
			size[0] = 4096;
			if (Posix._NSGetExecutablePath(path.ref(0), size.view().ref(0)) == 0) {
				var r = Posix.realpathExtsn(path.ref(0), buf.ref(0));
				return ofC(r.isNull() ? path.ref(0) : buf.ref(0));
			}
		}
		var n = Posix.readlink(cstr("/proc/self/exe"), buf.sub(0, 4096)).toInt();
		if (n > 0) {
			buf[n] = 0;
			return ofC(buf.ref(0));
		}
		if (argc() > 0) {
			var a0:Ref<UInt8> = Ref.raw(Mem.getPtr(argv(), 0));
			var r = mac() ? Posix.realpathExtsn(a0, buf.ref(0)) : Posix.realpath(a0, buf.ref(0));
			return ofC(r.isNull() ? a0 : buf.ref(0));
		}
		return "";
	}

	// struct termios: c_lflag at 12 (4 bytes) on Linux, at 24 (8) on macOS;
	// ICANON 2 / 0x100, ECHO 8 on both; TCSANOW 0
	public static function getChar(echo:Bool):Int {
		var old:Fixed<UInt8, 128> = Fixed.scratch(), raw:Fixed<UInt8, 128> = Fixed.scratch();
		var ov = old.view(), rv = raw.view();
		var tty = Posix.isatty(0) != 0 && Posix.tcgetattr(0, ov.ref(0)) == 0;
		if (tty) {
			raw = old;
			rv = raw.view();
			var off = mac() ? 24 : 12;
			var flags = (mac() ? 0x100 : 2) | (echo ? 0 : 8);
			LE.put32(rv, off, LE.i32(rv, off) & ~flags);
			Posix.tcsetattr(0, 0, rv.ref(0));
		}
		var c = new Fixed<UInt8, 8>();
		if (threads() > 1) Rt.rt_wait_fd(0, 0, -1);
		var r = Posix.read(0, c.view().sub(0, 1)).toInt();
		if (tty) Posix.tcsetattr(0, 0, ov.ref(0));
		if (r <= 0) Rt.rt_throw("Eof");
		return c[0];
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
		return Posix.open(cstr(path), flags | oCloexec(), 438); // 0666
	}

	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	// the bytes [pos, pos + len) of the Bytes b, a view for a call that does
	// not block (nothing collects during it)
	static inline function bytesView(b:Dynamic, pos:Int, len:Int):Slice<UInt8>
		return Slice.raw(Bytes.bytes(b).add(pos), len);

	public static function fileRead(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1 && Rt.rt_wait_fd(fd, 0, -1) < 0) return -1; // closed while waiting
		while (true) {
			// (ready: the read does not block, and nothing collects during it)
			var r = Posix.read(fd, bytesView(b, pos, len)).toInt();
			if (r < 0 && errno() == EINTR) continue;
			return r;
		}
	}

	public static function fileWrite(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1 && Rt.rt_wait_fd(fd, 1, -1) < 0) return -1;
		while (true) {
			var r = Posix.write(fd, bytesView(b, pos, len)).toInt();
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

	@:hxmc.scoped public static function fileTell(fd:Int):Int
		return Posix.lseek(fd, 0, 1).toInt();

	// struct stat (144 bytes or fewer): st_mode, st_size (and the rest for
	// stat()) per target
	static inline function stMode(st:Slice<UInt8>):Int
		return mac() ? LE.u16(st, 4) : Mem.arm() ? LE.i32(st, 16) : LE.i32(st, 24);

	static inline function stSize(st:Slice<UInt8>):I64
		return mac() ? LE.i64(st, 96) : LE.i64(st, 48);

	static inline function doStat(p:Ref<UInt8>, st:Slice<UInt8>):Int
		return inode64() ? Posix.statInode64(p, st.ref(0)) : Posix.stat(p, st.ref(0));

	static inline function doFstat(fd:Int, st:Slice<UInt8>):Int
		return inode64() ? Posix.fstatInode64(fd, st.ref(0)) : Posix.fstat(fd, st.ref(0));

	static inline function isReg(mode:Int):Bool
		return (mode & 0xF000) == 0x8000;

	static inline function isDir(mode:Int):Bool
		return (mode & 0xF000) == 0x4000;

	public static function fileContent(path:String):Dynamic {
		var fd = Posix.open(cstr(path), oCloexec(), 0);
		if (fd < 0) return null;
		// read into malloc'ed memory first: the size may not be known (pipes)
		var cap = 65536, n = 0;
		var st:Fixed<UInt8, 256> = Fixed.scratch(); // (C fills it)
		if (doFstat(fd, st.view()) == 0 && isReg(stMode(st.view()))) cap = stSize(st.view()).toInt() + 1;
		var buf = LibC.malloc(cap);
		while (true) {
			if (n == cap) {
				cap *= 2;
				buf = LibC.realloc(buf, cap);
			}
			var r = Posix.read(fd, Slice.raw(buf.add(n), cap - n)).toInt();
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
		var fd = Posix.open(cstr(path), 1 | oCreat() | oCloexec() | (append ? oAppend() : oTrunc()), 438);
		if (fd < 0) return false;
		return saveAll(fd, Bytes.bytes(b), Bytes.len(b));
	}

	@:hxmc.unsafe static function saveAll(fd:Int, d:Ptr, n:Int):Bool
		return SysCore.saveAll(fd, d, n);

	public static function exists(path:String):Bool {
		var st:Fixed<UInt8, 256> = Fixed.scratch(); // (C fills it)
		return doStat(cstr(path), st.view()) == 0;
	}

	public static function isDirectory(path:String):Bool {
		var st:Fixed<UInt8, 256> = Fixed.scratch(); // (C fills it)
		return doStat(cstr(path), st.view()) == 0 && isDir(stMode(st.view()));
	}

	public static function createDirectory(path:String):Bool
		return Posix.mkdir(cstr(path), 511) == 0; // 0777

	public static function deleteFile(path:String):Bool
		return Posix.unlink(cstr(path)) == 0;

	public static function deleteDirectory(path:String):Bool
		return Posix.rmdir(cstr(path)) == 0;

	public static function rename(path:String, newPath:String):Bool
		return Posix.rename(cstr(path), cstr(newPath)) == 0;

	// struct dirent: d_name at 19 (Linux), 21 (macOS, 64-bit inodes)
	public static function readDirectory(path:String):Array<String> {
		var p = cstr(path);
		var d = inode64() ? Posix.opendirInode64(p) : Posix.opendir(p);
		if (d.isNull()) return null;
		var names:Array<String> = [];
		var off = mac() ? 21 : 19;
		while (true) {
			var e = inode64() ? Posix.readdirInode64(d) : Posix.readdir(d);
			if (e.isNull()) break;
			var n = ofC(e, off); // (the directory stream is outside the heap)
			if (n != "." && n != "..") names.push(n);
		}
		Posix.closedir(d);
		return names;
	}

	public static function fullPath(path:String):String {
		var p = cstr(path);
		var buf:Slice<UInt8> = Scope.slice(4104);
		var r = mac() ? Posix.realpathExtsn(p, buf.ref(0)) : Posix.realpath(p, buf.ref(0));
		return r.isNull() ? null : ofC(buf.ref(0));
	}

	// Extc.get_real_path is get_full_path outside Windows
	public static function realPath(path:String):String
		return fullPath(path);

	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static function stat(path:String):Array<Float> {
		var buf:Fixed<UInt8, 256> = Fixed.scratch(); // (C fills it)
		var st = buf.view();
		if (doStat(cstr(path), st) != 0) return null;
		inline function f(v:I64):Float
			return cast v;
		inline function u(v:Int):Float
			return f((v : I64) & (((1 : I64) << 32) - 1));
		inline function i32(o:Int):Int
			return LE.i32(st, o);
		inline function i64(o:Int):I64
			return LE.i64(st, o);
		if (mac())
			return [
				u(i32(20)), u(i32(16)), f(i64(32)), f(i64(48)), f(i64(64)), u(i32(0)), f(i64(8)), LE.u16(st, 6), u(i32(24)), f(i64(96)),
				LE.u16(st, 4)
			];
		if (Mem.arm())
			return [
				u(i32(28)), u(i32(24)), f(i64(72)), f(i64(88)), f(i64(104)), f(i64(0)), f(i64(8)), u(i32(20)), f(i64(32)), f(i64(48)), u(i32(16))
			];
		return [
			u(i32(32)), u(i32(28)), f(i64(72)), f(i64(88)), f(i64(104)), f(i64(0)), f(i64(8)), f(i64(16)), f(i64(40)), f(i64(48)), u(i32(24))
		];
	}

	// ---- processes

	public static function processRun(cmd:String, args:Array<String>, fds:Array<Int>):Int {
		// argv in malloc'ed C strings before forking
		var n = Str.isNull(args) ? 0 : args.length;
		var argv = LibC.malloc(8 * (n + 4));
		if (!Str.isNull(args)) {
			Mem.setPtr(argv, 0, Str.toUtf8(cmd));
			for (i in 0...n)
				Mem.setPtr(argv, 8 * (i + 1), Str.toUtf8(args[i]));
			Mem.setPtr(argv, 8 * (n + 1), Ptr.nil());
		} else {
			Mem.setPtr(argv, 0, Str.toUtf8("/bin/sh"));
			Mem.setPtr(argv, 8, Str.toUtf8("-c"));
			Mem.setPtr(argv, 16, Str.toUtf8(cmd));
			Mem.setPtr(argv, 24, Ptr.nil());
			n = 2;
		}
		// in[2], out[2], err[2]
		var p = new Fixed<Int, 6>();
		var pid = pipes(p.view()) ? spawn(argv, p.view()) : -2;
		for (i in 0...n + 1)
			LibC.free(Mem.getPtr(argv, 8 * i));
		LibC.free(argv);
		if (pid == -2) Rt.rt_throw("Process creation failure");
		if (pid < 0) {
			Posix.close(p[1]);
			Posix.close(p[2]);
			Posix.close(p[4]);
			Rt.rt_throw("Process creation failure");
		}
		fds[0] = p[1];
		fds[1] = p[2];
		fds[2] = p[4];
		return pid;
	}

	// The three pipes (p: in[2], out[2], err[2]), close-on-exec from the start
	// (upstream's Unix.pipe ~cloexec:true): a process another thread starts
	// meanwhile must not inherit them (it would hold their ends open). pipe2
	// on Linux; macOS has no pipe2: pipe, then FD_CLOEXEC under the
	// descriptor lock, which fork takes too (spawn). False: a failure, with
	// nothing left open.
	@:hxmc.scoped static function pipes(p:Slice<Int>):Bool {
		if (!mac()) {
			for (k in 0...3)
				if (Posix.pipe2(p.ref(2 * k), oCloexec()) != 0) {
					closeFds(p, 2 * k);
					return false;
				}
			return true;
		}
		Threads.lockSafe(Gc.fdLock);
		var k = 0;
		while (k < 3 && Posix.pipe(p.ref(2 * k)) == 0)
			k++;
		for (i in 0...2 * k)
			Posix.fcntl(p[i], 2, 1); // F_SETFD, FD_CLOEXEC
		Os.unlock(Gc.fdLock);
		if (k == 3) return true;
		closeFds(p, 2 * k);
		return false;
	}

	@:hxmc.scoped static function closeFds(p:Slice<Int>, n:Int)
		for (i in 0...n)
			Posix.close(p[i]);

	// macOS: fd, a descriptor just created, close-on-exec; the caller holds
	// the descriptor lock (see pipes)
	@:hxmc.scoped public static function cloexec(fd:Int):Int {
		if (fd >= 0) Posix.fcntl(fd, 2, 1); // F_SETFD, FD_CLOEXEC
		return fd;
	}

	// fork and exec with the three pipes, all close-on-exec: the child's ends
	// become 0, 1 and 2 by dup2, which clears the flag, and exec closes the
	// rest; the child calls only the C library
	@:hxmc.unsafe static function spawn(argv:Ptr, p:Slice<Int>):Int {
		Posix.fflush(Ptr.nil());
		if (mac()) Threads.lockSafe(Gc.fdLock);
		var pid = Posix.fork();
		if (pid == 0) {
			for (k in 0...3) {
				var fd = p[k == 0 ? 0 : 2 * k + 1];
				// (dup2 of a descriptor onto itself keeps the flag)
				if (fd == k) Posix.fcntl(k, 2, 0) else Posix.dup2(fd, k);
			}
			Posix.execvp(Mem.getPtr(argv, 0), argv);
			Posix._exit(127);
		}
		if (mac()) Os.unlock(Gc.fdLock);
		Posix.close(p[0]);
		Posix.close(p[3]);
		Posix.close(p[5]);
		return pid;
	}

	// OS threads: waits in a safe region; WNOHANG 1
	public static function processWait(pid:Int, block:Bool):Int {
		var st = new Fixed<Int, 1>();
		while (true) {
			Leaf.rt_blocking_enter();
			var r = Posix.waitpid(pid, st.view().ref(0), block ? 0 : 1);
			Leaf.rt_blocking_leave();
			if (r < 0 && errno() == EINTR) continue;
			if (r <= 0) return -1;
			break;
		}
		return exitCode(st[0]);
	}

	@:hxmc.scoped public static function processKill(pid:Int):Void
		Posix.kill(pid, 9);
}
