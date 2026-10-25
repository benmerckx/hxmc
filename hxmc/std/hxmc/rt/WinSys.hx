package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.scoped.Fixed;
import hxmc.scoped.LE;
import hxmc.scoped.Ref;
import hxmc.scoped.Scope;
import hxmc.scoped.Slice;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt16;
import hxmc.unsafe.UInt8;
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
// processes' own. Over the C runtime and kernel32 (hxmc.unsafe.Win32), whose
// calls take views of scoped memory (docs/plans/lowlevel.md, "The scoped C
// boundary"): the wide strings on the data stack, the structures the system
// fills in Fixed buffers of the frame read little-endian (hxmc.scoped.LE).
class WinSys {
	static inline function threads():Int
		return Mem.getI32(Mem.sym("rt_nthreads"), 0);

	// s as a wide C string on the data stack (SysCore.wref)
	static inline function wide(s:String):Ref<UInt16>
		return SysCore.wref(s);

	// n units at p (outside the heap: the system's memory, the data stack) as a String
	static function ofUnits(p:Ptr, n:Int):String {
		var s = Str.make(n);
		LibC.memcpy(Str.unitsAddr(s), p, 2 * n);
		return s;
	}

	// the wide C string at r, memory of the system's, as a String (null for none)
	static function ofWide(r:Ref<UInt16>):String
		return r.isNull() ? null : ofUnits(r.ptr(), Win32.wcslen(r).toInt());

	static inline function ofC(p:Ptr):String
		return Str.ofUtf8(p, LibC.strlen(p).toInt());

	@:hxmc.scoped static function errno():Int
		return Win32._errno().value;

	@:hxmc.scoped static function writeAll(fd:Int, s:Slice<UInt8>) {
		var p = 0;
		while (p < s.length) {
			var w = Win32._write(fd, s.sub(p, s.length - p));
			if (w <= 0) return;
			p += w;
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

	public static function getEnv(s:String):String
		return ofWide(Win32._wgetenv(wide(s)));

	// _wputenv_s updates the C runtime's table and the process environment
	// (which child processes inherit); an empty value removes the variable
	public static function putEnv(s:String, v:String):Void
		Win32._wputenv_s(wide(s), wide(Str.isNull(v) ? "" : v));

	// the process environment ("=C:=C:\..." entries included: Sys.environment skips them)
	public static function environ():Array<String> {
		var block = Win32.GetEnvironmentStringsW();
		var a:Array<String> = [];
		if (block.isNull()) return a;
		// (copied out first: the strings allocate)
		var e = block;
		var n = 0;
		while (Mem.getU16(e, 0) != 0) {
			e = e.add(2 * (Win32.wcslen(Ref.raw(e)).toInt() + 1));
			n++;
		}
		e = block;
		for (_ in 0...n) {
			a.push(ofWide(Ref.raw(e)));
			e = e.add(2 * (Win32.wcslen(Ref.raw(e)).toInt() + 1));
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
		var s = ofWide(Ref.raw(w));
		LibC.free(w);
		var n = Str.len(s);
		if (n == 0 || (Str.unit(s, n - 1) != "/".code && Str.unit(s, n - 1) != "\\".code)) s = Str.concat(s, "/");
		return s;
	}

	public static function setCwd(s:String):Bool
		return Win32._wchdir(wide(s)) == 0;

	public static function systemName():String
		return "Windows";

	public static function hostSystem():String
		return "Windows";

	// Sys.command: the C runtime's _wsystem (%COMSPEC% /c cmd), whose result
	// is the exit code (OCaml's caml_sys_system_command on Windows)
	public static function command(cmd:String):Int {
		var w = wide(cmd);
		Leaf.rt_blocking_enter();
		var r = Win32._wsystem(w); // (w is on the data stack: no heap address)
		Leaf.rt_blocking_leave();
		return r;
	}

	// Sys.command quotes its arguments for cmd.exe on Windows (the hxmc std's Sys)
	public static function commandArgs(cmd:String, args:Array<String>):Int
		return -2;

	public static function exit(code:Int):Void {
		Win32.fflush(Ptr.nil());
		Win32.exit(code);
	}

	// seconds since the epoch: a FILETIME counts 100 ns from 1601
	@:hxmc.scoped public static function time():Float {
		var ft = new Fixed<I64, 1>();
		Win32.GetSystemTimePreciseAsFileTime(ft.view().ref(0));
		var t:Float = cast(ft[0] - ((116444736 : I64) * (1000000000 : I64)));
		return t / 1e7;
	}

	// user and kernel time of the process (clock() is wall-clock time on Windows)
	@:hxmc.scoped public static function cpuTime():Float {
		var t = new Fixed<I64, 4>();
		var v = t.view();
		if (Win32.GetProcessTimes(Win32.GetCurrentProcess(), v.ref(0), v.ref(1), v.ref(2), v.ref(3)) == 0) return 0;
		var s:Float = cast(t[2] + t[3]);
		return s / 1e7;
	}

	public static function programPath():String {
		var buf:Slice<UInt16> = Scope.slice(32768);
		var n = Win32.GetModuleFileNameW(Ptr.nil(), buf);
		return n == 0 || n >= 32768 ? (argc() > 0 ? ofC(Mem.getPtr(argv(), 0)) : "") : ofWide(buf.ref(0));
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
		var c = new Fixed<UInt8, 8>();
		var b = c.view().sub(0, 1);
		Leaf.rt_blocking_enter();
		var r = Win32._read(0, b);
		Leaf.rt_blocking_leave();
		if (r <= 0) Rt.rt_throw("Eof");
		if (echo) Win32._write(1, b);
		return c[0];
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
		return Win32._wopen(wide(path), flags | 0x8000 | 0x80, 0x180);
	}

	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	// The heap's reservations are committed page by page on first touch, by an
	// exception handler (rt_win.c), which a fault inside the kernel never
	// reaches: ReadFile, WriteFile or recv on an untouched page of a Bytes fails
	// (ERROR_NOACCESS) where user code would have committed it. So the pages of
	// a buffer the system reads or writes are touched first (a byte of each
	// page read and written back); a view passed to C is touched by the call
	// (hx_view_touch, FnLower.cCall).
	@:hxmc.unsafe public static function touch(p:Ptr, n:Int) {
		var off = 0;
		while (off < n) {
			Mem.setI8(p, off, Mem.getU8(p, off));
			off += 4096;
		}
		if (n > 0) Mem.setI8(p, n - 1, Mem.getU8(p, n - 1));
	}

	// len bytes of b at pos, a view for a call that does not block: the heap's
	// own memory (no collection can move it meanwhile)
	@:hxmc.unsafe static inline function heapView(b:Dynamic, pos:Int, len:Int):Slice<UInt8>
		return Slice.raw(Bytes.bytes(b).add(pos), len);

	// Reads and writes of pipes and consoles block: with other threads they go
	// through a buffer on the data stack in a safe region (a collection may
	// move the Bytes; the data stacks do not move)
	public static function fileRead(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1) {
			var tmp:Slice<UInt8> = Scope.scratch(len > 0 ? len : 1);
			Leaf.rt_blocking_enter();
			var r = Win32._read(fd, tmp.sub(0, len));
			Leaf.rt_blocking_leave();
			if (r > 0) Slice.copyBytes(heapView(b, pos, r), 0, tmp, 0, r);
			return r;
		}
		return Win32._read(fd, heapView(b, pos, len));
	}

	public static function fileWrite(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (threads() > 1) {
			var tmp:Slice<UInt8> = Scope.scratch(len > 0 ? len : 1);
			Slice.copyBytes(tmp, 0, heapView(b, pos, len), 0, len);
			Leaf.rt_blocking_enter();
			var r = Win32._write(fd, tmp.sub(0, len));
			Leaf.rt_blocking_leave();
			return r;
		}
		return Win32._write(fd, heapView(b, pos, len));
	}

	public static function fileClose(fd:Int):Void {
		Leaf.rt_fd_closed(fd);
		Win32._close(fd);
	}

	public static function fileSeek(fd:Int, p:Int, whence:Int):Void {
		if (Win32._lseeki64(fd, p, whence < 0 || whence > 2 ? 0 : whence) < 0) Rt.rt_throw("seek failed");
	}

	@:hxmc.unsafe public static function fileTell(fd:Int):Int
		return Win32._telli64(fd).toInt();

	// struct _stat64 (UCRT): st_dev u32 0, st_ino u16 4, st_mode u16 6,
	// st_nlink i16 8, st_uid i16 10, st_gid i16 12, st_rdev u32 16, st_size
	// 24, st_atime 32, st_mtime 40, st_ctime 48 (64-bit)
	static inline var STAT = 64;

	static inline function i16(v:Slice<UInt8>, at:Int):Int
		return (LE.u16(v, at) << 16) >> 16;

	public static function fileContent(path:String):Dynamic {
		var fd = Win32._wopen(wide(path), 0x8000 | 0x80, 0);
		if (fd < 0) return null;
		var cap = 65536, n = 0;
		var st:Fixed<UInt8, 64> = Fixed.scratch(); // (C fills it)
		var sv = st.view();
		if (Win32._fstat64(fd, sv.ref(0)) == 0 && (LE.u16(sv, 6) & 0xF000) == 0x8000) cap = LE.i64(sv, 24).toInt() + 1;
		var buf = LibC.malloc(cap);
		while (true) {
			if (n == cap) {
				cap *= 2;
				buf = LibC.realloc(buf, cap);
			}
			var r = Win32._read(fd, Slice.raw(buf.add(n), cap - n));
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
		var fd = Win32._wopen(wide(path), 1 | 0x100 | 0x8000 | 0x80 | (append ? 8 : 0x200), 0x180);
		if (fd < 0) return false;
		return saveAll(fd, Bytes.bytes(b), Bytes.len(b));
	}

	@:hxmc.unsafe static function saveAll(fd:Int, d:Ptr, n:Int):Bool
		return SysCore.saveAll(fd, d, n);

	// Sys.file_exists, Sys.is_directory: _wstat64; the mode, or -1
	static function pathMode(path:String):Int {
		var st:Fixed<UInt8, 64> = Fixed.scratch(); // (C fills it)
		var sv = st.view();
		return Win32._wstat64(wide(path), sv.ref(0)) == 0 ? LE.u16(sv, 6) : -1;
	}

	public static function exists(path:String):Bool
		return pathMode(path) >= 0;

	public static function isDirectory(path:String):Bool {
		var m = pathMode(path);
		return m >= 0 && (m & 0xF000) == 0x4000;
	}

	public static function createDirectory(path:String):Bool
		return Win32._wmkdir(wide(path)) == 0;

	// caml_win32_unlink: a read-only file is made writable, then removed
	public static function deleteFile(path:String):Bool
		return deleteW(wide(path)) == 0;

	@:hxmc.scoped static function deleteW(p:Ref<UInt16>):Int {
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

	public static function deleteDirectory(path:String):Bool
		return Win32._wrmdir(wide(path)) == 0;

	// caml_win32_rename: MoveFileEx replacing the target, a directory over an
	// empty directory, never a directory over a file
	public static function rename(path:String, newPath:String):Bool
		return renameW(wide(path), wide(newPath));

	@:hxmc.scoped static function renameW(a:Ref<UInt16>, b:Ref<UInt16>):Bool {
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

	// the name of a WIN32_FIND_DATAW, a String
	static function findName(data:Slice<UInt8>):String {
		var n = 0;
		while (n < 260 && LE.u16(data, FIND_NAME + 2 * n) != 0)
			n++;
		return ofUnits(data.ptr().add(FIND_NAME), n);
	}

	// Sys.readdir (caml_read_directory: FindFirstFile over dir\*)
	public static function readDirectory(path:String):Array<String> {
		var n = Str.len(path);
		var last = n > 0 ? Str.unit(path, n - 1) : 0;
		var pat = n > 0 && last != "/".code && last != "\\".code && last != ":".code ? Str.concat(path, "\\*") : Str.concat(path, "*");
		var data:Slice<UInt8> = Scope.slice(FIND_DATA);
		var h = Win32.FindFirstFileW(wide(pat), data.ref(0));
		if (h.toI64() == -1) {
			if (Win32.GetLastError() != 2) return null; // ERROR_FILE_NOT_FOUND
			return [];
		}
		var names:Array<String> = [];
		do {
			var c0 = LE.u16(data, FIND_NAME), c1 = LE.u16(data, FIND_NAME + 2);
			var dot = c0 == ".".code && (c1 == 0 || (c1 == ".".code && LE.u16(data, FIND_NAME + 4) == 0));
			if (!dot) names.push(findName(data));
		} while (Win32.FindNextFileW(h, data.ref(0)) != 0);
		Win32.FindClose(h);
		return names;
	}

	// Extc.get_full_path: GetFullPathName (the file need not exist)
	public static function fullPath(path:String):String {
		var p = wide(path);
		var n = Win32.GetFullPathNameW(p, 0, Ref.nil(), Ptr.nil());
		if (n == 0) return null;
		var buf:Slice<UInt16> = Scope.slice(n + 1);
		var m = Win32.GetFullPathNameW(p, n + 1, buf.ref(0), Ptr.nil());
		return m == 0 || m > n ? null : ofWide(buf.ref(0));
	}

	// Extc.get_real_path: the full path with the drive letter upper-cased and
	// each existing component as the file system spells it
	public static function realPath(path:String):String {
		var p = wide(path);
		var n = Win32.GetFullPathNameW(p, 0, Ref.nil(), Ptr.nil());
		if (n == 0) return null;
		var cap = n + 1 + 4 * 260;
		var out:Slice<UInt16> = Scope.slice(cap);
		var m = Win32.GetFullPathNameW(p, n + 1, out.ref(0), Ptr.nil());
		if (m == 0 || m > n) return null;
		var len = 0;
		while (out[len] != 0)
			len++;
		return ofUnits(out.ptr(), realPathW(out, len));
	}

	// each component of the full path out (len units, a 0 after) as the file
	// system spells it, in place: the new length
	static function realPathW(out:Slice<UInt16>, len:Int):Int {
		var i = 0;
		if (len >= 2 && out[1] == ":".code) {
			if (out[0] >= "a".code && out[0] <= "z".code) out[0] = out[0] - 32;
			i = len >= 3 && out[2] == "\\".code ? 3 : 2;
		}
		var last = i;
		var data:Slice<UInt8> = Scope.slice(FIND_DATA);
		while (i < len) {
			while (i < len && out[i] != "\\".code)
				i++;
			out[i] = 0;
			var h = Win32.FindFirstFileW(out.ref(0), data.ref(0));
			if (!(h.toI64() == -1)) {
				var klen = 0;
				while (klen < 260 && LE.u16(data, FIND_NAME + 2 * klen) != 0)
					klen++;
				if (klen != i - last && len + klen < out.length) { // a ~ (short name) was expanded
					var d = klen - (i - last);
					// (the rest, its 0 included, moved by d units)
					if (d > 0) {
						var k = len;
						while (k >= i) {
							out[k + d] = out[k];
							k--;
						}
					} else
						for (k in i...len + 1)
							out[k + d] = out[k];
					len += d;
					i += d;
				}
				if (klen == i - last)
					for (k in 0...klen)
						out[last + k] = LE.u16(data, FIND_NAME + 2 * k);
				Win32.FindClose(h);
			}
			if (i < len) out[i] = "\\".code;
			i++;
			last = i;
		}
		return len;
	}

	// Unix.stat as Windows' C runtime fills it (uid, gid, ino: 0)
	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static function stat(path:String):Array<Float> {
		var st:Fixed<UInt8, 64> = Fixed.scratch(); // (C fills it)
		var v = st.view();
		if (Win32._wstat64(wide(path), v.ref(0)) != 0) return null;
		inline function f(x:I64):Float
			return cast x;
		inline function u32(at:Int):Float
			return f((LE.i32(v, at) : I64) & (((1 : I64) << 32) - 1));
		return [
			i16(v, 12), i16(v, 10), f(LE.i64(v, 32)), f(LE.i64(v, 40)), f(LE.i64(v, 48)), u32(0), LE.u16(v, 4), i16(v, 8), u32(16), f(LE.i64(v, 24)),
			LE.u16(v, 6)
		];
	}

	// ---- processes: ids of processes this process created, with their
	// handles, in a malloc'ed table (pid, handle) under a spin lock
	// (rt_spin[1]); handles are made inheritable only for the CreateProcess
	// they are for (rt_spin[2])

	static var procs:Ptr;
	static var nprocs:Int;
	static var procsCap:Int;

	@:hxmc.unsafe static function lock(k:Int) {
		var l = Mem.sym("rt_spin").add(4 * k);
		while (Atomic.cas32(l, 0, 1) != 0)
			Win32.Sleep(0);
	}

	@:hxmc.unsafe static function unlock(k:Int)
		Atomic.store32(Mem.sym("rt_spin").add(4 * k), 0);

	static inline function handle(x:I64):Ptr
		return new Ptr(x);

	// a copy of the process's handle (closed by the caller), null when unknown
	@:hxmc.unsafe static function procHandle(pid:Int):Ptr {
		var h = new Fixed<I64, 1>();
		var self = Win32.GetCurrentProcess();
		lock(1);
		for (i in 0...nprocs)
			if (Mem.getI64(procs, 16 * i) == (pid : I64)
				&& Win32.DuplicateHandle(self, Mem.getPtr(procs, 16 * i + 8), self, h.view().ref(0), 0, 0, 2) == 0) // DUPLICATE_SAME_ACCESS
				h[0] = 0;
		unlock(1);
		return handle(h[0]);
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
	// (on the data stack, a 0 after)
	static function searchExe(name:Ref<UInt16>, ext:Ref<UInt16>):Slice<UInt16> {
		var n = Win32.SearchPathW(Ptr.nil(), name, ext, 0, Ref.nil(), Ptr.nil());
		if (n > 0) {
			var f:Slice<UInt16> = Scope.slice(n + 1);
			var m = Win32.SearchPathW(Ptr.nil(), name, ext, n + 1, f.ref(0), Ptr.nil());
			if (m > 0 && m <= n) return f;
		}
		var l = Win32.wcslen(name).toInt();
		var c:Slice<UInt16> = Scope.slice(l + 1), src:Slice<UInt16> = Slice.raw(name.ptr(), l);
		for (k in 0...l)
			c[k] = src[k];
		return c;
	}

	public static function processRun(cmd:String, args:Array<String>, fds:Array<Int>):Int {
		var line:String;
		var exe:Slice<UInt16>;
		var ext = wide(".exe");
		if (!Str.isNull(args)) {
			// Unix.create_process cmd (cmd :: args)
			var b = new StringBuf();
			cmdlineAdd(b, true, cmd);
			for (a in args)
				cmdlineAdd(b, false, a);
			line = b.toString();
			exe = searchExe(wide(cmd), ext);
		} else {
			// Unix.open_process_full: %COMSPEC% /c cmd
			var shell = Win32._wgetenv(wide("COMSPEC"));
			if (shell.isNull()) return -1;
			line = Str.concat(Str.concat(ofWide(shell), " /c "), cmd);
			exe = searchExe(shell, ext);
		}
		var r = new Fixed<Int, 4>();
		if (!spawn(exe.ref(0), wide(line), r.view())) return -1;
		fds[0] = r[0];
		fds[1] = r[1];
		fds[2] = r[2];
		return r[3];
	}

	// CreateProcess with three pipes: r its in, out and err descriptors and
	// its pid; false on a failure
	@:hxmc.unsafe static function spawn(exe:Ref<UInt16>, wline:Ref<UInt16>, r:Slice<Int>):Bool {
		// pipes: the child's ends are inheritable copies, the parent's are not
		var sa = new Fixed<UInt8, 24>();
		var sv = sa.view();
		LE.put64(sv, 0, 24); // nLength (and padding); lpSecurityDescriptor null, bInheritHandle FALSE
		var hs = new Fixed<I64, 6>(); // in_r, in_w, out_r, out_w, err_r, err_w
		var hv = hs.view();
		if (Win32.CreatePipe(hv.ref(0), hv.ref(1), sv.ref(0), 0) == 0) return false;
		if (Win32.CreatePipe(hv.ref(2), hv.ref(3), sv.ref(0), 0) == 0) {
			Win32.CloseHandle(handle(hs[0]));
			Win32.CloseHandle(handle(hs[1]));
			return false;
		}
		if (Win32.CreatePipe(hv.ref(4), hv.ref(5), sv.ref(0), 0) == 0) {
			for (k in 0...4)
				Win32.CloseHandle(handle(hs[k]));
			return false;
		}
		// STARTUPINFOW (104 bytes): cb, dwFlags at 60, wShowWindow at 64,
		// hStdInput 80, hStdOutput 88, hStdError 96
		var si = new Fixed<UInt8, 104>();
		var siv = si.view();
		LE.put32(siv, 0, 104);
		var siFlags = 0x100; // STARTF_USESTDHANDLES
		var flags = 0x400; // CREATE_UNICODE_ENVIRONMENT
		if (!hasConsole()) {
			flags |= 0x10; // CREATE_NEW_CONSOLE
			siFlags |= 1; // STARTF_USESHOWWINDOW
			LE.put16(siv, 64, 0); // SW_HIDE
		}
		LE.put32(siv, 60, siFlags);
		var pi = new Fixed<UInt8, 24>(); // hProcess, hThread, dwProcessId, dwThreadId
		var piv = pi.view();
		var std = new Fixed<I64, 3>(); // the child's ends, inheritable
		var stdv = std.view();
		var self = Win32.GetCurrentProcess();
		lock(2);
		Win32.DuplicateHandle(self, handle(hs[0]), self, stdv.ref(0), 0, 1, 2);
		Win32.DuplicateHandle(self, handle(hs[3]), self, stdv.ref(1), 0, 1, 2);
		Win32.DuplicateHandle(self, handle(hs[5]), self, stdv.ref(2), 0, 1, 2);
		for (k in 0...3)
			LE.put64(siv, 80 + 8 * k, std[k]);
		var ok = Win32.CreateProcessW(exe, wline, Ptr.nil(), Ptr.nil(), 1, flags, Ptr.nil(), Ptr.nil(), siv.ref(0), piv.ref(0)) != 0;
		for (k in 0...3)
			Win32.CloseHandle(handle(std[k]));
		unlock(2);
		Win32.CloseHandle(handle(hs[0]));
		Win32.CloseHandle(handle(hs[3]));
		Win32.CloseHandle(handle(hs[5]));
		if (!ok) {
			Win32.CloseHandle(handle(hs[1]));
			Win32.CloseHandle(handle(hs[2]));
			Win32.CloseHandle(handle(hs[4]));
			return false;
		}
		Win32.CloseHandle(handle(LE.i64(piv, 8)));
		var pid = LE.i32(piv, 16);
		lock(1);
		if (nprocs == procsCap) {
			procsCap = procsCap > 0 ? procsCap * 2 : 16;
			procs = LibC.realloc(procs, 16 * procsCap);
		}
		Mem.setI64(procs, 16 * nprocs, pid);
		Mem.setI64(procs, 16 * nprocs + 8, LE.i64(piv, 0));
		nprocs++;
		unlock(1);
		r[0] = pipeFd(handle(hs[1]), 1); // _O_WRONLY
		r[1] = pipeFd(handle(hs[2]), 0); // _O_RDONLY
		r[2] = pipeFd(handle(hs[4]), 0);
		r[3] = pid;
		return true;
	}

	// CONOUT$ opens when the process has a console
	static function hasConsole():Bool {
		// GENERIC_WRITE, FILE_SHARE_WRITE, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL
		var h = Win32.CreateFileW(wide("CONOUT$"), 0x40000000, 2, Ptr.nil(), 3, 0x80, Ptr.nil());
		if (h.toI64() == -1) return false;
		Win32.CloseHandle(h);
		return true;
	}

	// the parent's end of a pipe as a descriptor (_O_BINARY | _O_NOINHERIT)
	@:hxmc.unsafe static function pipeFd(h:Ptr, flags:Int):Int {
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

	@:hxmc.unsafe static function reap(pid:Int, h:Ptr, r:Int):Int {
		var code = new Fixed<Int, 1>();
		var got = r == 0 && Win32.GetExitCodeProcess(h, code.view().ref(0)) != 0; // WAIT_OBJECT_0
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
		return code[0];
	}

	// Unix.kill pid Sys.sigkill: TerminateProcess with exit code 0
	@:hxmc.unsafe public static function processKill(pid:Int):Void {
		var h = procHandle(pid);
		if (!h.isNull()) {
			Win32.TerminateProcess(h, 0);
			Win32.CloseHandle(h);
		}
	}
}
