package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.Win32;

// The operating-system primitives of hxmc.NativeSys on Windows (formerly
// rt_sys_win.c; NativeSys calls them only there). They behave
// as the OCaml runtime and Unix library do on Windows, which the reference
// compiler is built with: paths, environment variables and command lines
// are UTF-16 (the W functions: Haxe's own units, NUL-terminated copies);
// files and pipes are C runtime descriptors in binary mode; a command line
// runs through %COMSPEC% /c (Sys.command: _wsystem; a Process without
// arguments: Unix.open_process_full); a program with arguments is found as
// Unix.create_process finds it (SearchPath with .exe) and its command line
// quotes the arguments as Unix.make_cmdline does; exit codes are the
// processes' own.
class WinSys {
	static inline function threads():Int
		return Mem.getI32(Mem.sym("rt_nthreads"), 0);

	// a malloc'ed NUL-terminated UTF-16 copy of s
	@:hxmc.noGc static function wide(s:String):Ptr {
		var n = Str.len(s);
		var w = LibC.malloc(2 * n + 2);
		LibC.memcpy(w, Str.unitsAddr(s), 2 * n);
		Mem.setI16(w, 2 * n, 0);
		return w;
	}

	@:hxmc.noGc static function wlen(w:Ptr):Int {
		var n = 0;
		while (Mem.getU16At(w, 0, n) != 0)
			n++;
		return n;
	}

	// a NUL-terminated UTF-16 string (outside the heap) as a String
	static function ofWide(w:Ptr):String {
		var n = wlen(w);
		var s = Str.make(n);
		LibC.memcpy(Str.unitsAddr(s), w, 2 * n);
		return s;
	}

	static inline function ofC(p:Ptr):String
		return Str.ofUtf8(p, LibC.strlen(p).toInt());

	@:hxmc.noGc static function errno():Int
		return Mem.getI32(Win32._errno(), 0);

	@:hxmc.noGc static function writeAll(fd:Int, p:Ptr, n:Int) {
		while (n > 0) {
			var w = Win32._write(fd, p, n);
			if (w <= 0) return;
			p = p.add(w);
			n -= w;
		}
	}

	static function printTo(fd:Int, s:String)
		SysCore.printTo(fd, s);

	public static function print(s:String):Void
		printTo(1, s);

	public static function printErr(s:String):Void
		printTo(2, s);

	static inline function argc():Int
		return Mem.getI32(Mem.sym("rt_argc"), 0);

	static inline function argv():Ptr
		return Mem.getPtr(Mem.sym("rt_argv"), 0);

	public static function args():Array<String> {
		var a:Array<String> = [];
		for (i in 1...argc())
			a.push(ofC(Mem.getPtr(argv(), 8 * i)));
		return a;
	}

	public static function argv0():String
		return argc() > 0 ? ofC(Mem.getPtr(argv(), 0)) : null;

	public static function getEnv(s:String):String {
		var n = wide(s);
		var v = Win32._wgetenv(n);
		var r = v.isNull() ? null : ofWide(v);
		LibC.free(n);
		return r;
	}

	// _wputenv_s updates the C runtime's table and the process environment
	// (which child processes inherit); an empty value removes the variable
	public static function putEnv(s:String, v:String):Void {
		var n = wide(s);
		var w = Str.isNull(v) ? wide("") : wide(v);
		Win32._wputenv_s(n, w);
		LibC.free(n);
		LibC.free(w);
	}

	// the process environment ("=C:=C:\..." entries included: Sys.environment skips them)
	public static function environ():Array<String> {
		var block = Win32.GetEnvironmentStringsW();
		var a:Array<String> = [];
		if (block.isNull()) return a;
		// (copied out first: the strings allocate)
		var e = block;
		var n = 0;
		while (Mem.getU16(e, 0) != 0) {
			e = e.add(2 * (wlen(e) + 1));
			n++;
		}
		e = block;
		for (_ in 0...n) {
			a.push(ofWide(e));
			e = e.add(2 * (wlen(e) + 1));
		}
		Win32.FreeEnvironmentStringsW(block);
		return a;
	}

	public static function sleep(seconds:Float):Void {
		if (threads() > 1) {
			Rt.rt_sleep(seconds);
			return;
		}
		if (seconds <= 0) return;
		Win32.Sleep(Std.int(seconds * 1000.0 + 0.5));
	}

	// _wgetcwd has no trailing separator but at a drive's root ("C:\")
	public static function getCwd():String {
		var w = Win32._wgetcwd(Ptr.nil(), 0);
		if (w.isNull()) Rt.rt_throw("getCwd failed");
		var s = ofWide(w);
		LibC.free(w);
		var n = Str.len(s);
		if (n == 0 || (Str.unit(s, n - 1) != "/".code && Str.unit(s, n - 1) != "\\".code)) s = Str.concat(s, "/");
		return s;
	}

	public static function setCwd(s:String):Bool {
		var w = wide(s);
		var r = Win32._wchdir(w);
		LibC.free(w);
		return r == 0;
	}

	public static function systemName():String
		return "Windows";

	public static function hostSystem():String
		return "Windows";

	// Sys.command: the C runtime's _wsystem (%COMSPEC% /c cmd), whose result
	// is the exit code (OCaml's caml_sys_system_command on Windows)
	public static function command(cmd:String):Int {
		var w = wide(cmd);
		Leaf.rt_blocking_enter();
		var r = Win32._wsystem(w); // w is malloc'ed: no heap address
		Leaf.rt_blocking_leave();
		LibC.free(w);
		return r;
	}

	// Sys.command quotes its arguments for cmd.exe on Windows (the hxmc std's Sys)
	public static function commandArgs(cmd:String, args:Array<String>):Int
		return -2;

	public static function exit(code:Int):Void {
		Win32.fflush(Ptr.nil());
		Win32.exit(code);
	}

	// a FILETIME (100 ns units) as a 64-bit count
	static inline function filetime(p:Ptr):I64
		return Mem.getI64(p, 0);

	// seconds since the epoch: FILETIME counts 100 ns from 1601
	@:hxmc.noGc public static function time():Float {
		var ft = Mem.stack(8);
		Win32.GetSystemTimePreciseAsFileTime(ft);
		var t:Float = cast(filetime(ft) - ((116444736 : I64) * (1000000000 : I64)));
		return t / 1e7;
	}

	// user and kernel time of the process (clock() is wall-clock time on Windows)
	@:hxmc.noGc public static function cpuTime():Float {
		var t = Mem.stack(32);
		if (Win32.GetProcessTimes(Win32.GetCurrentProcess(), t, t.add(8), t.add(16), t.add(24)) == 0) return 0;
		var s:Float = cast(filetime(t.add(16)) + filetime(t.add(24)));
		return s / 1e7;
	}

	public static function programPath():String {
		var buf = LibC.malloc(65536);
		var n = Win32.GetModuleFileNameW(Ptr.nil(), buf, 32768);
		var s = n == 0 || n >= 32768 ? (argc() > 0 ? ofC(Mem.getPtr(argv(), 0)) : "") : ofWide(buf);
		LibC.free(buf);
		return s;
	}

	// extc's sys_getch: the console without line buffering, or a byte of a
	// redirected standard input
	public static function getChar(echo:Bool):Int {
		var h = Win32.GetStdHandle(-10); // STD_INPUT_HANDLE
		var ft = !(h.toI64() == -1) ? Win32.GetFileType(h) : 2; // FILE_TYPE_CHAR
		if (ft == 2) {
			Leaf.rt_blocking_enter();
			var c = echo ? Win32._getche() : Win32._getch();
			Leaf.rt_blocking_leave();
			return c;
		}
		var c = Mem.stack(8);
		Leaf.rt_blocking_enter();
		var r = Win32._read(0, c, 1);
		Leaf.rt_blocking_leave();
		if (r <= 0) Rt.rt_throw("Eof");
		if (echo) Win32._write(1, c, 1);
		return Mem.getU8(c, 0);
	}

	// ---- files: C runtime descriptors in binary mode, not inherited
	// (_O_WRONLY 1, _O_RDWR 2, _O_APPEND 8, _O_CREAT 0x100, _O_TRUNC 0x200,
	// _O_BINARY 0x8000, _O_NOINHERIT 0x80; _S_IREAD | _S_IWRITE 0x180)

	public static function fileOpen(path:String, mode:Int):Int {
		var flags = switch mode {
			case 0: 0;
			case 1: 1 | 0x100 | 0x200;
			case 2: 1 | 0x100 | 8;
			case 3: 2 | 0x100;
			case _: return -1;
		}
		var p = wide(path);
		var fd = Win32._wopen(p, flags | 0x8000 | 0x80, 0x180);
		LibC.free(p);
		return fd;
	}

	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	// The heap's reservations are committed page by page on first touch, by an
	// exception handler (rt_win.c), which a fault inside the kernel never
	// reaches: ReadFile, WriteFile or recv on an untouched page of a Bytes fails
	// (ERROR_NOACCESS) where user code would have committed it. So the pages of
	// a buffer the system reads or writes are touched first (a byte of each
	// page read and written back).
	@:hxmc.noGc public static function touch(p:Ptr, n:Int) {
		var off = 0;
		while (off < n) {
			Mem.setI8(p, off, Mem.getU8(p, off));
			off += 4096;
		}
		if (n > 0) Mem.setI8(p, n - 1, Mem.getU8(p, n - 1));
	}

	@:hxmc.noGc static function readHeap(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		var p = Bytes.bytes(b).add(pos);
		touch(p, len);
		return Win32._read(fd, p, len);
	}

	@:hxmc.noGc static function writeHeap(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		var p = Bytes.bytes(b).add(pos);
		touch(p, len);
		return Win32._write(fd, p, len);
	}

	// Reads and writes of pipes and consoles block: with other threads they go
	// through a malloc'ed buffer in a safe region (a collection may move the Bytes)
	public static function fileRead(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1) {
			var tmp = LibC.malloc(len > 0 ? len : 1);
			Leaf.rt_blocking_enter();
			var r = Win32._read(fd, tmp, len);
			Leaf.rt_blocking_leave();
			if (r > 0) LibC.memcpy(Bytes.bytes(b).add(pos), tmp, r);
			LibC.free(tmp);
			return r;
		}
		return readHeap(fd, b, pos, len);
	}

	public static function fileWrite(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1) {
			var tmp = LibC.malloc(len > 0 ? len : 1);
			LibC.memcpy(tmp, Bytes.bytes(b).add(pos), len);
			Leaf.rt_blocking_enter();
			var r = Win32._write(fd, tmp, len);
			Leaf.rt_blocking_leave();
			LibC.free(tmp);
			return r;
		}
		return writeHeap(fd, b, pos, len);
	}

	public static function fileClose(fd:Int):Void {
		Leaf.rt_fd_closed(fd);
		Win32._close(fd);
	}

	public static function fileSeek(fd:Int, p:Int, whence:Int):Void {
		if (Win32._lseeki64(fd, p, whence < 0 || whence > 2 ? 0 : whence) < 0) Rt.rt_throw("seek failed");
	}

	@:hxmc.noGc public static function fileTell(fd:Int):Int
		return Win32._telli64(fd).toInt();

	// struct _stat64 (UCRT): st_dev u32 0, st_ino u16 4, st_mode u16 6,
	// st_nlink i16 8, st_uid i16 10, st_gid i16 12, st_rdev u32 16, st_size
	// 24, st_atime 32, st_mtime 40, st_ctime 48 (64-bit)
	static inline function stMode(st:Ptr):Int
		return Mem.getU16(st, 6);

	public static function fileContent(path:String):Dynamic {
		var p = wide(path);
		var fd = Win32._wopen(p, 0x8000 | 0x80, 0);
		LibC.free(p);
		if (fd < 0) return null;
		var cap = 65536, n = 0;
		var st = Mem.stack(64);
		if (Win32._fstat64(fd, st) == 0 && (stMode(st) & 0xF000) == 0x8000) cap = Mem.getI64(st, 24).toInt() + 1;
		var buf = LibC.malloc(cap);
		while (true) {
			if (n == cap) {
				cap *= 2;
				buf = LibC.realloc(buf, cap);
			}
			var r = Win32._read(fd, buf.add(n), cap - n);
			if (r < 0) {
				LibC.free(buf);
				Win32._close(fd);
				return null;
			}
			if (r == 0) break;
			n += r;
		}
		Win32._close(fd);
		var b = Bytes.alloc(n);
		LibC.memcpy(Bytes.bytes(b), buf, n);
		LibC.free(buf);
		return b;
	}

	public static function fileSave(path:String, b:Dynamic, append:Bool):Bool {
		var p = wide(path);
		var fd = Win32._wopen(p, 1 | 0x100 | 0x8000 | 0x80 | (append ? 8 : 0x200), 0x180);
		LibC.free(p);
		if (fd < 0) return false;
		return saveAll(fd, Bytes.bytes(b), Bytes.len(b));
	}

	@:hxmc.noGc static function saveAll(fd:Int, d:Ptr, n:Int):Bool
		return SysCore.saveAll(fd, d, n);

	// Sys.file_exists, Sys.is_directory: _wstat64
	@:hxmc.noGc static function pathStat(p:Ptr, st:Ptr):Int
		return Win32._wstat64(p, st);

	public static function exists(path:String):Bool {
		var p = wide(path);
		var st = Mem.stack(64);
		var r = pathStat(p, st) == 0;
		LibC.free(p);
		return r;
	}

	public static function isDirectory(path:String):Bool {
		var p = wide(path);
		var st = Mem.stack(64);
		var r = pathStat(p, st) == 0 && (stMode(st) & 0xF000) == 0x4000;
		LibC.free(p);
		return r;
	}

	public static function createDirectory(path:String):Bool {
		var p = wide(path);
		var r = Win32._wmkdir(p) == 0;
		LibC.free(p);
		return r;
	}

	// caml_win32_unlink: a read-only file is made writable, then removed
	public static function deleteFile(path:String):Bool {
		var p = wide(path);
		var r = deleteW(p);
		LibC.free(p);
		return r == 0;
	}

	@:hxmc.noGc static function deleteW(p:Ptr):Int {
		var r = Win32._wunlink(p);
		if (r == -1 && errno() == 13) { // EACCES
			var attrs = Win32.GetFileAttributesW(p);
			if (attrs != -1 && (attrs & 1) != 0 && Win32.SetFileAttributesW(p, attrs & ~1) != 0) { // FILE_ATTRIBUTE_READONLY
				r = Win32._wunlink(p);
				if (r == -1) Win32.SetFileAttributesW(p, attrs);
			}
		}
		return r;
	}

	public static function deleteDirectory(path:String):Bool {
		var p = wide(path);
		var r = Win32._wrmdir(p) == 0;
		LibC.free(p);
		return r;
	}

	// caml_win32_rename: MoveFileEx replacing the target, a directory over an
	// empty directory, never a directory over a file
	public static function rename(path:String, newPath:String):Bool {
		var a = wide(path), b = wide(newPath);
		var ok = renameW(a, b);
		LibC.free(a);
		LibC.free(b);
		return ok;
	}

	@:hxmc.noGc static function renameW(a:Ptr, b:Ptr):Bool {
		// MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH; FILE_ATTRIBUTE_DIRECTORY 0x10
		var flags = 1 | 2 | 8;
		var na = -1, oa = Win32.GetFileAttributesW(a);
		if (oa != -1 && (oa & 0x10) != 0) {
			na = Win32.GetFileAttributesW(b);
			if (na != -1 && (na & 0x10) == 0) return false;
		}
		if (Win32.MoveFileExW(a, b, flags) != 0) return true;
		if (oa != -1 && (oa & 0x10) != 0 && na != -1 && (na & 0x10) != 0) {
			Win32.RemoveDirectoryW(b);
			return Win32.MoveFileExW(a, b, flags) != 0;
		}
		return false;
	}

	// WIN32_FIND_DATAW: cFileName (260 units) at 44, 592 bytes
	static inline var FIND_DATA = 592;
	static inline var FIND_NAME = 44;

	// Sys.readdir (caml_read_directory: FindFirstFile over dir\*)
	public static function readDirectory(path:String):Array<String> {
		var n = Str.len(path);
		var last = n > 0 ? Str.unit(path, n - 1) : 0;
		var pat = n > 0 && last != "/".code && last != "\\".code && last != ":".code ? Str.concat(path, "\\*") : Str.concat(path, "*");
		var w = wide(pat);
		var fd = LibC.malloc(FIND_DATA);
		var h = Win32.FindFirstFileW(w, fd);
		LibC.free(w);
		if (h.toI64() == -1) {
			LibC.free(fd);
			if (Win32.GetLastError() != 2) return null; // ERROR_FILE_NOT_FOUND
			return [];
		}
		var names:Array<String> = [];
		do {
			var name = fd.add(FIND_NAME);
			var dot = Mem.getU16(name, 0) == ".".code && (Mem.getU16(name, 2) == 0 || (Mem.getU16(name, 2) == ".".code && Mem.getU16(name, 4) == 0));
			if (!dot) names.push(ofWide(name)); // (the find data is outside the heap)
		} while (Win32.FindNextFileW(h, fd) != 0);
		Win32.FindClose(h);
		LibC.free(fd);
		return names;
	}

	// Extc.get_full_path: GetFullPathName (the file need not exist)
	public static function fullPath(path:String):String {
		var p = wide(path);
		var n = Win32.GetFullPathNameW(p, 0, Ptr.nil(), Ptr.nil());
		if (n == 0) {
			LibC.free(p);
			return null;
		}
		var buf = LibC.malloc(2 * (n + 1));
		var m = Win32.GetFullPathNameW(p, n + 1, buf, Ptr.nil());
		LibC.free(p);
		var s = m == 0 || m > n ? null : ofWide(buf);
		LibC.free(buf);
		return s;
	}

	// Extc.get_real_path: the full path with the drive letter upper-cased and
	// each existing component as the file system spells it
	public static function realPath(path:String):String {
		var p = wide(path);
		var out = realPathW(p);
		LibC.free(p);
		if (out.isNull()) return null;
		var s = ofWide(out);
		LibC.free(out);
		return s;
	}

	@:hxmc.noGc static function realPathW(p:Ptr):Ptr {
		var n = Win32.GetFullPathNameW(p, 0, Ptr.nil(), Ptr.nil());
		if (n == 0) return Ptr.nil();
		var cap = n + 1 + 4 * 260;
		var out = LibC.malloc(2 * cap);
		var m = Win32.GetFullPathNameW(p, n + 1, out, Ptr.nil());
		if (m == 0 || m > n) {
			LibC.free(out);
			return Ptr.nil();
		}
		inline function at(k:Int):Int
			return Mem.getU16At(out, 0, k);
		inline function put(k:Int, v:Int)
			Mem.setU16At(out, 0, k, v);
		var len = wlen(out), i = 0;
		if (len >= 2 && at(1) == ":".code) {
			if (at(0) >= "a".code && at(0) <= "z".code) put(0, at(0) - 32);
			i = len >= 3 && at(2) == "\\".code ? 3 : 2;
		}
		var last = i;
		var data = LibC.malloc(FIND_DATA);
		while (i < len) {
			while (i < len && at(i) != "\\".code)
				i++;
			put(i, 0);
			var h = Win32.FindFirstFileW(out, data);
			if (!(h.toI64() == -1)) {
				var name = data.add(FIND_NAME);
				var klen = wlen(name);
				if (klen != i - last && len + klen < cap) { // a ~ (short name) was expanded
					var d = klen - (i - last);
					LibC.memmove(out.add(2 * (i + d)), out.add(2 * i), 2 * (len - i + 1));
					len += d;
					i += d;
				}
				if (klen == i - last) LibC.memcpy(out.add(2 * last), name, 2 * klen);
				Win32.FindClose(h);
			}
			if (i < len) put(i, "\\".code);
			i++;
			last = i;
		}
		LibC.free(data);
		return out;
	}

	// Unix.stat as Windows' C runtime fills it (uid, gid, ino: 0)
	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static function stat(path:String):Array<Float> {
		var p = wide(path);
		var st = Mem.stack(64);
		var r = pathStat(p, st);
		LibC.free(p);
		if (r != 0) return null;
		inline function f(v:I64):Float
			return cast v;
		inline function u32(v:Int):Float
			return f((v : I64) & (((1 : I64) << 32) - 1));
		return [
			Mem.getI16(st, 12), Mem.getI16(st, 10), f(Mem.getI64(st, 32)), f(Mem.getI64(st, 40)), f(Mem.getI64(st, 48)), u32(Mem.getI32(st, 0)),
			Mem.getU16(st, 4), Mem.getI16(st, 8), u32(Mem.getI32(st, 16)), f(Mem.getI64(st, 24)), Mem.getU16(st, 6)
		];
	}

	// ---- processes: ids of processes this process created, with their
	// handles, in a malloc'ed table (pid, handle) under a spin lock
	// (rt_spin[1]); handles are made inheritable only for the CreateProcess
	// they are for (rt_spin[2])

	static var procs:Ptr;
	static var nprocs:Int;
	static var procsCap:Int;

	@:hxmc.noGc static function lock(k:Int) {
		var l = Mem.sym("rt_spin").add(4 * k);
		while (Atomic.cas32(l, 0, 1) != 0)
			Win32.Sleep(0);
	}

	@:hxmc.noGc static function unlock(k:Int)
		Atomic.store32(Mem.sym("rt_spin").add(4 * k), 0);

	// a copy of the process's handle (closed by the caller), null when unknown
	@:hxmc.noGc static function procHandle(pid:Int):Ptr {
		var h = Mem.stack(8);
		Mem.setPtr(h, 0, Ptr.nil());
		var self = Win32.GetCurrentProcess();
		lock(1);
		for (i in 0...nprocs)
			if (Mem.getI64(procs, 16 * i) == (pid : I64)
				&& Win32.DuplicateHandle(self, Mem.getPtr(procs, 16 * i + 8), self, h, 0, 0, 2) == 0) // DUPLICATE_SAME_ACCESS
				Mem.setPtr(h, 0, Ptr.nil());
		unlock(1);
		return Mem.getPtr(h, 0);
	}

	// Unix.make_cmdline's maybe_quote: Filename.quote (the C runtime's
	// argument parsing rules) when the argument is empty or holds a space,
	// tab or quote
	static function cmdlineAdd(b:StringBuf, first:Bool, s:String) {
		if (!first) b.addChar(" ".code);
		var l = Str.len(s);
		var plain = l > 0;
		for (i in 0...l) {
			var c = Str.unit(s, i);
			if (c == " ".code || c == "\"".code || c == "\t".code) plain = false;
		}
		if (plain) {
			b.add(s);
			return;
		}
		b.addChar("\"".code);
		var bs = 0;
		for (i in 0...l) {
			var c = Str.unit(s, i);
			if (c == "\\".code) {
				bs++;
				continue;
			}
			for (_ in 0...(c == "\"".code ? 2 * bs + 1 : bs))
				b.addChar("\\".code);
			bs = 0;
			b.addChar(c);
		}
		for (_ in 0...2 * bs)
			b.addChar("\\".code);
		b.addChar("\"".code);
	}

	// caml_search_exe_in_path: SearchPath with .exe, else the name as given
	// (a malloc'ed wide string)
	@:hxmc.noGc static function searchExe(name:Ptr, ext:Ptr):Ptr {
		var n = Win32.SearchPathW(Ptr.nil(), name, ext, 0, Ptr.nil(), Ptr.nil());
		if (n > 0) {
			var f = LibC.malloc(2 * (n + 1));
			var m = Win32.SearchPathW(Ptr.nil(), name, ext, n + 1, f, Ptr.nil());
			if (m > 0 && m <= n) return f;
			LibC.free(f);
		}
		var l = wlen(name);
		var c = LibC.malloc(2 * l + 2);
		LibC.memcpy(c, name, 2 * l + 2);
		return c;
	}

	public static function processRun(cmd:String, args:Array<String>, fds:Array<Int>):Int {
		var line:String;
		var exe:Ptr;
		var ext = wide(".exe");
		if (!Str.isNull(args)) {
			// Unix.create_process cmd (cmd :: args)
			var b = new StringBuf();
			cmdlineAdd(b, true, cmd);
			for (a in args)
				cmdlineAdd(b, false, a);
			line = b.toString();
			var wc = wide(cmd);
			exe = searchExe(wc, ext);
			LibC.free(wc);
		} else {
			// Unix.open_process_full: %COMSPEC% /c cmd
			var cs = wide("COMSPEC");
			var shell = Win32._wgetenv(cs);
			LibC.free(cs);
			if (shell.isNull()) {
				LibC.free(ext);
				return -1;
			}
			line = Str.concat(Str.concat(ofWide(shell), " /c "), cmd);
			exe = searchExe(Win32._wgetenv(wide("COMSPEC")), ext);
		}
		LibC.free(ext);
		var wline = wide(line);
		var r = spawn(exe, wline);
		LibC.free(exe);
		LibC.free(wline);
		if (r.isNull()) return -1;
		fds[0] = Mem.getI32(r, 0);
		fds[1] = Mem.getI32(r, 4);
		fds[2] = Mem.getI32(r, 8);
		var pid = Mem.getI32(r, 12);
		LibC.free(r);
		return pid;
	}

	// CreateProcess with three pipes: a malloc'ed {in fd, out fd, err fd,
	// pid}, or null
	@:hxmc.noGc static function spawn(exe:Ptr, wline:Ptr):Ptr {
		// pipes: the child's ends are inheritable copies, the parent's are not
		var sa = Mem.stack(24);
		Mem.setI64(sa, 0, 24); // nLength (and padding)
		Mem.setPtr(sa, 8, Ptr.nil());
		Mem.setI64(sa, 16, 0); // bInheritHandle FALSE
		var hs = Mem.stack(48); // in_r, in_w, out_r, out_w, err_r, err_w
		if (Win32.CreatePipe(hs, hs.add(8), sa, 0) == 0) return Ptr.nil();
		if (Win32.CreatePipe(hs.add(16), hs.add(24), sa, 0) == 0) {
			Win32.CloseHandle(Mem.getPtr(hs, 0));
			Win32.CloseHandle(Mem.getPtr(hs, 8));
			return Ptr.nil();
		}
		if (Win32.CreatePipe(hs.add(32), hs.add(40), sa, 0) == 0) {
			for (k in 0...4)
				Win32.CloseHandle(Mem.getPtr(hs, 8 * k));
			return Ptr.nil();
		}
		// STARTUPINFOW (104 bytes): cb, dwFlags at 60, wShowWindow at 64,
		// hStdInput 80, hStdOutput 88, hStdError 96
		var si = Mem.stack(104);
		LibC.memset(si, 0, 104);
		Mem.setI32(si, 0, 104);
		var siFlags = 0x100; // STARTF_USESTDHANDLES
		var flags = 0x400; // CREATE_UNICODE_ENVIRONMENT
		if (!hasConsole()) {
			flags |= 0x10; // CREATE_NEW_CONSOLE
			siFlags |= 1; // STARTF_USESHOWWINDOW
			Mem.setI16(si, 64, 0); // SW_HIDE
		}
		Mem.setI32(si, 60, siFlags);
		var pi = Mem.stack(24); // hProcess, hThread, dwProcessId, dwThreadId
		var self = Win32.GetCurrentProcess();
		lock(2);
		Win32.DuplicateHandle(self, Mem.getPtr(hs, 0), self, si.add(80), 0, 1, 2);
		Win32.DuplicateHandle(self, Mem.getPtr(hs, 24), self, si.add(88), 0, 1, 2);
		Win32.DuplicateHandle(self, Mem.getPtr(hs, 40), self, si.add(96), 0, 1, 2);
		var ok = Win32.CreateProcessW(exe, wline, Ptr.nil(), Ptr.nil(), 1, flags, Ptr.nil(), Ptr.nil(), si, pi) != 0;
		Win32.CloseHandle(Mem.getPtr(si, 80));
		Win32.CloseHandle(Mem.getPtr(si, 88));
		Win32.CloseHandle(Mem.getPtr(si, 96));
		unlock(2);
		Win32.CloseHandle(Mem.getPtr(hs, 0));
		Win32.CloseHandle(Mem.getPtr(hs, 24));
		Win32.CloseHandle(Mem.getPtr(hs, 40));
		if (!ok) {
			Win32.CloseHandle(Mem.getPtr(hs, 8));
			Win32.CloseHandle(Mem.getPtr(hs, 16));
			Win32.CloseHandle(Mem.getPtr(hs, 32));
			return Ptr.nil();
		}
		Win32.CloseHandle(Mem.getPtr(pi, 8));
		var pid = Mem.getI32(pi, 16);
		lock(1);
		if (nprocs == procsCap) {
			procsCap = procsCap > 0 ? procsCap * 2 : 16;
			procs = LibC.realloc(procs, 16 * procsCap);
		}
		Mem.setI64(procs, 16 * nprocs, pid);
		Mem.setPtr(procs, 16 * nprocs + 8, Mem.getPtr(pi, 0));
		nprocs++;
		unlock(1);
		var r = LibC.malloc(16);
		Mem.setI32(r, 0, pipeFd(Mem.getPtr(hs, 8), 1)); // _O_WRONLY
		Mem.setI32(r, 4, pipeFd(Mem.getPtr(hs, 16), 0)); // _O_RDONLY
		Mem.setI32(r, 8, pipeFd(Mem.getPtr(hs, 32), 0));
		Mem.setI32(r, 12, pid);
		return r;
	}

	// CONOUT$ opens when the process has a console
	@:hxmc.noGc static function hasConsole():Bool {
		var name = LibC.malloc(16);
		var s = "CONOUT$";
		for (i in 0...7)
			Mem.setU16At(name, 0, i, Str.unit(s, i));
		Mem.setI16(name, 14, 0);
		// GENERIC_WRITE, FILE_SHARE_WRITE, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL
		var h = Win32.CreateFileW(name, 0x40000000, 2, Ptr.nil(), 3, 0x80, Ptr.nil());
		LibC.free(name);
		if (h.toI64() == -1) return false;
		Win32.CloseHandle(h);
		return true;
	}

	// the parent's end of a pipe as a descriptor (_O_BINARY | _O_NOINHERIT)
	@:hxmc.noGc static function pipeFd(h:Ptr, flags:Int):Int {
		var fd = Win32._open_osfhandle(h, flags | 0x8000 | 0x80);
		if (fd < 0) Win32.CloseHandle(h);
		return fd;
	}

	// the exit code (Windows exit codes are 32 bits: a negative Int for codes
	// such as 0xC0000005), or -1 while the process runs
	public static function processWait(pid:Int, block:Bool):Int {
		var h = procHandle(pid);
		if (h.isNull()) return -1;
		Leaf.rt_blocking_enter();
		var r = Win32.WaitForSingleObject(h, block ? -1 : 0); // INFINITE
		Leaf.rt_blocking_leave();
		return reap(pid, h, r);
	}

	@:hxmc.noGc static function reap(pid:Int, h:Ptr, r:Int):Int {
		var code = Mem.stack(8);
		var got = r == 0 && Win32.GetExitCodeProcess(h, code) != 0; // WAIT_OBJECT_0
		Win32.CloseHandle(h);
		if (!got) return -1;
		// reaped: the handle is closed (the std caches the exit code)
		lock(1);
		for (i in 0...nprocs)
			if (Mem.getI64(procs, 16 * i) == (pid : I64)) {
				Win32.CloseHandle(Mem.getPtr(procs, 16 * i + 8));
				nprocs--;
				Mem.setI64(procs, 16 * i, Mem.getI64(procs, 16 * nprocs));
				Mem.setPtr(procs, 16 * i + 8, Mem.getPtr(procs, 16 * nprocs + 8));
				break;
			}
		unlock(1);
		return Mem.getI32(code, 0);
	}

	// Unix.kill pid Sys.sigkill: TerminateProcess with exit code 0
	@:hxmc.noGc public static function processKill(pid:Int):Void {
		var h = procHandle(pid);
		if (!h.isNull()) {
			Win32.TerminateProcess(h, 0);
			Win32.CloseHandle(h);
		}
	}
}
