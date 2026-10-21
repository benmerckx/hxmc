package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.wasm.Heap;
import hxmc.rt.wasm.Wasm;
import hxmc.rt.wasm.Wasi;
import hxmc.rt.wasm.WasiApi;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The operating-system primitives of hxmc.NativeSys on WebAssembly (WASI
// preview 1; NativeSys calls them only there): files and directories
// through the preopened directories (paths resolve against $PWD when a
// preopened directory covers it, else against "."), arguments, environment, clocks, standard
// streams. No processes (Sys.command, sys.io.Process throw).
class WasiSys {
	static inline var EINTR = 27;
	// rights: everything (the runtime narrows them)
	static inline function rights():I64
		return ((1 : I64) << 29) - 1;

	static inline function a32(p:Ptr):Int
		return Wasi.a32(p);

	static inline function cstr(s:String):Ptr
		return Str.toUtf8(s);

	static inline function ofC(p:Ptr):String
		return Str.ofUtf8(p, Heap.strlen(p).toInt());

	static function unsupported(what:String):Dynamic {
		Rt.rt_throw(what + " is not supported on WASI");
		return null;
	}

	public static function print(s:String):Void
		Wasi.writeStr(1, Str.orNull(s));

	public static function printErr(s:String):Void
		Wasi.writeStr(2, Str.orNull(s));

	public static function args():Array<String> {
		var a:Array<String> = [];
		for (i in 1...Wasi.argCount())
			a.push(ofC(Wasi.arg(i)));
		return a;
	}

	public static function argv0():String
		return Wasi.argCount() > 0 ? ofC(Wasi.arg(0)) : null;

	public static function getEnv(s:String):String {
		var n = cstr(s);
		var v = Wasi.getenv(n);
		Heap.free(n);
		return v.isNull() ? null : ofC(v);
	}

	// a new environment block without `s`, and with s=v
	public static function putEnv(s:String, v:String):Void {
		var n = cstr(s);
		var len = Heap.strlen(n).toInt();
		var count = Wasi.envCount();
		var e = Heap.calloc(count + 2, 8);
		var k = 0;
		for (i in 0...count) {
			var x = Wasi.envAt(i);
			if (Heap.memcmp(x, n, len) == 0 && Mem.getU8(x, len) == "=".code) continue;
			Mem.setPtr(e, 8 * k, x);
			k++;
		}
		if (!Str.isNull(v)) {
			var u = cstr(v);
			var vl = Heap.strlen(u).toInt();
			var x = Heap.malloc(len + vl + 2);
			Wasm.memcpy(x, n, len);
			Mem.setI8(x, len, "=".code);
			Wasm.memcpy(x.add(len + 1), u, vl + 1);
			Heap.free(u);
			Mem.setPtr(e, 8 * k, x);
			k++;
		}
		Heap.free(n);
		Wasi.setEnvBlock(e, k);
	}

	public static function environ():Array<String> {
		var a:Array<String> = [];
		for (i in 0...Wasi.envCount())
			a.push(ofC(Wasi.envAt(i)));
		return a;
	}

	public static function sleep(seconds:Float):Void {
		if (seconds <= 0) return;
		// one clock subscription (monotonic, relative)
		var sub = Mem.stack(48), ev = Mem.stack(32), n = Mem.stack(8);
		Wasm.memset(sub, 0, 48);
		Mem.setI32(sub, 16, 1);
		var ns:I64 = cast(seconds * 1e9);
		Mem.setI64(sub, 24, ns);
		WasiApi.poll_oneoff(a32(sub), a32(ev), 1, a32(n));
	}

	public static function getCwd():String {
		var c = Wasi.getCwd();
		if (c.isNull()) return "./";
		var s = ofC(c);
		return s.length > 0 && s.charCodeAt(s.length - 1) == "/".code ? s : s + "/";
	}

	public static function setCwd(s:String):Bool {
		if (!isDirectory(s)) return false;
		var p = cstr(s);
		var a = Wasi.absolute(p);
		Heap.free(p);
		if (Mem.getU8(a, 0) != "/".code) {
			Heap.free(a);
			return false;
		}
		Wasi.setCwd(a);
		return true;
	}

	public static function systemName():String
		return "Wasi";

	public static function hostSystem():String
		return systemName();

	public static function command(cmd:String):Int
		return unsupported("Sys.command");

	public static function commandArgs(cmd:String, args:Array<String>):Int
		return unsupported("Sys.command");

	@:hxmc.noGc public static function exit(code:Int):Void {
		Wasi.exit(code);
	}

	@:hxmc.noGc public static function time():Float {
		var ns:Float = cast Wasi.clockNs(0);
		return ns / 1e9;
	}

	@:hxmc.noGc public static function cpuTime():Float {
		var ns:Float = cast Wasi.clockNs(2);
		if (ns == 0) ns = cast Wasi.clockNs(1);
		return ns / 1e9;
	}

	public static function programPath():String
		return argv0() == null ? "" : argv0();

	public static function getChar(echo:Bool):Int {
		var c = Mem.stack(16);
		Mem.setI32(c, 4, a32(c.add(12)));
		Mem.setI32(c, 8, 1);
		if (WasiApi.fd_read(0, a32(c.add(4)), 1, a32(c)) != 0 || Mem.getI32(c, 0) <= 0) Rt.rt_throw("Eof");
		return Mem.getU8(c, 12);
	}

	// ---- paths

	// opens path relative to its preopened directory: the fd, or -1
	// access: 1 read, 2 write, 3 both
	@:hxmc.noGc static function open(path:Ptr, oflags:Int, fdflags:Int, access:Int):Int {
		var a = Wasi.absolute(path);
		var rel = Mem.stack(8);
		var dir = Wasi.resolve(a, rel);
		var r = -1;
		if (dir >= 0) {
			var out = Mem.stack(24);
			var rp = Mem.getPtr(rel, 0);
			// the rights of the access, of those the directory hands down (as
			// wasi-libc asks): FD_DATASYNC 0, FD_READ 1, FD_WRITE 6,
			// FD_ALLOCATE 8, FD_READDIR 14, FD_FILESTAT_SET_SIZE 22
			var inh = rights();
			if (WasiApi.fd_fdstat_get(dir, a32(out)) == 0) inh = Mem.getI64(out, 16);
			var max = ~(((1 << 0) | (1 << 1) | (1 << 6) | (1 << 8) | (1 << 14) | (1 << 22)) : I64);
			if ((access & 1) != 0) max = max | (((1 << 1) | (1 << 14)) : I64);
			if ((access & 2) != 0) max = max | (((1 << 0) | (1 << 6) | (1 << 8) | (1 << 22)) : I64);
			if (WasiApi.path_open(dir, 1, a32(rp), Heap.strlen(rp).toInt(), oflags, max & inh, inh, fdflags, a32(out)) == 0) r = Mem.getI32(out, 0);
		}
		Heap.free(a);
		return r;
	}

	// an operation on a path: 0 stat (into buf), 1 mkdir, 2 unlink, 3 rmdir; the errno, -1 without a preopen
	@:hxmc.noGc static function pathOp(path:Ptr, op:Int, buf:Ptr):Int {
		var a = Wasi.absolute(path);
		var rel = Mem.stack(8);
		var dir = Wasi.resolve(a, rel);
		var r = -1;
		if (dir >= 0) {
			var rp = Mem.getPtr(rel, 0);
			var n = Heap.strlen(rp).toInt();
			r = switch op {
				case 0: WasiApi.path_filestat_get(dir, 1, a32(rp), n, a32(buf));
				case 1: WasiApi.path_create_directory(dir, a32(rp), n);
				case 2: WasiApi.path_unlink_file(dir, a32(rp), n);
				case _: WasiApi.path_remove_directory(dir, a32(rp), n);
			}
		}
		Heap.free(a);
		return r;
	}

	// ---- files

	public static function fileOpen(path:String, mode:Int):Int {
		// oflags: CREAT 1, TRUNC 8; fdflags: APPEND 1
		var oflags = 0, fdflags = 0;
		switch mode {
			case 0:
			case 1:
				oflags = 1 | 8;
			case 2:
				oflags = 1;
				fdflags = 1;
			case 3:
				oflags = 1;
			case _:
				return -1;
		}
		var p = cstr(path);
		var fd = open(p, oflags, fdflags, mode == 0 ? 1 : mode == 3 ? 3 : 2);
		Heap.free(p);
		return fd;
	}

	static inline function outside()
		throw haxe.io.Error.OutsideBounds;

	@:hxmc.noGc static function rw(write:Bool, fd:Int, p:Ptr, n:Int):Int {
		var io = Mem.stack(16);
		Mem.setI32(io, 0, a32(p));
		Mem.setI32(io, 4, n);
		var r = write ? WasiApi.fd_write(fd, a32(io), 1, a32(io.add(8))) : WasiApi.fd_read(fd, a32(io), 1, a32(io.add(8)));
		return r == 0 ? Mem.getI32(io, 8) : -1;
	}

	public static function fileRead(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (fd == 0) Wasi.flush();
		return rw(false, fd, Bytes.bytes(b).add(pos), len);
	}

	public static function fileWrite(fd:Int, b:Dynamic, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		if (fd == 1 || fd == 2) {
			Wasi.write(fd, Bytes.bytes(b).add(pos), len);
			return len;
		}
		return rw(true, fd, Bytes.bytes(b).add(pos), len);
	}

	// (Sys.stdout().flush(): what a callback printed, after main returned)
	@:hxmc.noGc public static function fileFlush(fd:Int):Void
		if (fd == 1) Wasi.flush();

	@:hxmc.noGc public static function fileClose(fd:Int):Void {
		if (fd == 1) Wasi.flush();
		WasiApi.fd_close(fd);
	}

	public static function fileSeek(fd:Int, p:Int, whence:Int):Void {
		var out = Mem.stack(8);
		if (WasiApi.fd_seek(fd, p, whence < 0 || whence > 2 ? 0 : whence, a32(out)) != 0) Rt.rt_throw("seek failed");
	}

	@:hxmc.noGc public static function fileTell(fd:Int):Int {
		var out = Mem.stack(8);
		if (WasiApi.fd_tell(fd, a32(out)) != 0) return -1;
		return Mem.getI64(out, 0).toInt();
	}

	public static function fileContent(path:String):Dynamic {
		var p = cstr(path);
		var fd = open(p, 0, 0, 1);
		Heap.free(p);
		if (fd < 0) return null;
		var cap = 65536, n = 0;
		var st = Mem.stack(64);
		if (WasiApi.fd_filestat_get(fd, a32(st)) == 0 && Mem.getU8(st, 16) == 4) cap = Mem.getI64(st, 32).toInt() + 1;
		var buf = Heap.malloc(cap);
		while (true) {
			if (n == cap) {
				cap *= 2;
				buf = Heap.realloc(buf, cap);
			}
			var r = rw(false, fd, buf.add(n), cap - n);
			if (r < 0) {
				Heap.free(buf);
				WasiApi.fd_close(fd);
				return null;
			}
			if (r == 0) break;
			n += r;
		}
		WasiApi.fd_close(fd);
		var b = Bytes.alloc(n);
		Wasm.memcpy(Bytes.bytes(b), buf, n);
		Heap.free(buf);
		return b;
	}

	public static function fileSave(path:String, b:Dynamic, append:Bool):Bool {
		var p = cstr(path);
		var fd = open(p, append ? 1 : 1 | 8, append ? 1 : 0, 2);
		Heap.free(p);
		if (fd < 0) return false;
		return saveAll(fd, Bytes.bytes(b), Bytes.len(b));
	}

	@:hxmc.noGc static function saveAll(fd:Int, d:Ptr, n:Int):Bool {
		var ok = true;
		while (n > 0) {
			var w = rw(true, fd, d, n);
			if (w <= 0) {
				ok = false;
				break;
			}
			d = d.add(w);
			n -= w;
		}
		return WasiApi.fd_close(fd) == 0 && ok;
	}

	// the file type of a path (filestat.filetype: 3 directory, 4 regular file), -1: none
	static function fileType(path:String):Int {
		var p = cstr(path);
		var st = Mem.stack(64);
		var r = pathOp(p, 0, st);
		// (a directory above the preopened ones: a directory)
		var t = r == 0 ? Mem.getU8(st, 16) : Wasi.preopenAncestor(p) ? 3 : -1;
		Heap.free(p);
		return t;
	}

	public static function exists(path:String):Bool
		return fileType(path) >= 0;

	public static function isDirectory(path:String):Bool
		return fileType(path) == 3;

	static function simple(path:String, op:Int):Bool {
		var p = cstr(path);
		var r = pathOp(p, op, Ptr.nil());
		Heap.free(p);
		return r == 0;
	}

	public static function createDirectory(path:String):Bool
		return simple(path, 1);

	public static function deleteFile(path:String):Bool
		return simple(path, 2);

	public static function deleteDirectory(path:String):Bool
		return simple(path, 3);

	public static function rename(path:String, newPath:String):Bool {
		var p = cstr(path), q = cstr(newPath);
		var a = Wasi.absolute(p), b = Wasi.absolute(q);
		Heap.free(p);
		Heap.free(q);
		var ra = Mem.stack(8), rb = Mem.stack(8);
		var da = Wasi.resolve(a, ra), db = Wasi.resolve(b, rb);
		var ok = false;
		if (da >= 0 && db >= 0) {
			var x = Mem.getPtr(ra, 0), y = Mem.getPtr(rb, 0);
			ok = WasiApi.path_rename(da, a32(x), Heap.strlen(x).toInt(), db, a32(y), Heap.strlen(y).toInt()) == 0;
		}
		Heap.free(a);
		Heap.free(b);
		return ok;
	}

	public static function readDirectory(path:String):Array<String> {
		var p = cstr(path);
		var fd = open(p, 2, 0, 1); // O_DIRECTORY
		Heap.free(p);
		if (fd < 0) return null;
		var names:Array<String> = [];
		var cap = 4096;
		var buf = Heap.malloc(cap);
		var used = Mem.stack(8);
		var cookie:I64 = 0;
		while (true) {
			if (WasiApi.fd_readdir(fd, a32(buf), cap, cookie, a32(used)) != 0) break;
			var n = Mem.getI32(used, 0);
			var at = 0;
			var progress = false;
			// dirent: d_next u64, d_ino u64, d_namlen u32, d_type u8; the name after 24 bytes
			while (at + 24 <= n) {
				var len = Mem.getI32(buf, at + 16);
				if (at + 24 + len > n) break;
				var name = buf.add(at + 24);
				cookie = Mem.getI64(buf, at);
				progress = true;
				var dot = len == 1 && Mem.getU8(name, 0) == ".".code;
				var dotdot = len == 2 && Mem.getU8(name, 0) == ".".code && Mem.getU8(name, 1) == ".".code;
				if (!dot && !dotdot) names.push(Str.ofUtf8(buf.add(at + 24), len));
				at += 24 + len;
			}
			if (n < cap && at >= n) break;
			if (!progress) {
				// an entry larger than the buffer
				cap *= 2;
				buf = Heap.realloc(buf, cap);
			}
		}
		Heap.free(buf);
		WasiApi.fd_close(fd);
		return names;
	}

	// the absolute normalized path (no symbolic links resolved)
	public static function fullPath(path:String):String {
		if (!exists(path)) return null;
		var p = cstr(path);
		var a = Wasi.absolute(p);
		Heap.free(p);
		var s = ofC(a);
		Heap.free(a);
		return s;
	}

	public static function realPath(path:String):String
		return fullPath(path);

	// gid uid atime mtime ctime dev ino nlink rdev size mode
	public static function stat(path:String):Array<Float> {
		var p = cstr(path);
		var st = Mem.stack(64);
		var r = pathOp(p, 0, st);
		Heap.free(p);
		if (r != 0) return null;
		inline function f(v:I64):Float
			return cast v;
		var ft = Mem.getU8(st, 16);
		var mode = ft == 3 ? 0x41ED : ft == 4 ? 0x81A4 : ft == 7 ? 0xA1FF : 0;
		return [
			0, 0, f(Mem.getI64(st, 40) / 1000000000), f(Mem.getI64(st, 48) / 1000000000), f(Mem.getI64(st, 56) / 1000000000), f(Mem.getI64(st, 0)),
			f(Mem.getI64(st, 8)), f(Mem.getI64(st, 24)), 0, f(Mem.getI64(st, 32)), mode
		];
	}

	// ---- processes: none

	public static function processRun(cmd:String, args:Array<String>, fds:Array<Int>):Int
		return unsupported("sys.io.Process");

	public static function processWait(pid:Int, block:Bool):Int
		return unsupported("sys.io.Process");

	public static function processKill(pid:Int):Void
		unsupported("sys.io.Process");
}
