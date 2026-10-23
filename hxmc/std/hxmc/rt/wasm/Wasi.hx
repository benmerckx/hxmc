package hxmc.rt.wasm;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The runtime's view of WASI: the arguments and the environment (read once),
// the preopened directories and path resolution, buffered standard output.
@:hxmc.wasm @:keep
class Wasi {
	static inline var OUTBUF = 65536;

	static var argc:Int;
	static var argv:Ptr; // 8-byte pointers to C strings
	static var nenv:Int;
	static var env:Ptr; // 8-byte pointers to "NAME=value"
	static var npre:Int;
	static var pre:Ptr; // (fd, name) pairs of 16 bytes: int32 fd, then a C string pointer
	static var cwd:Ptr; // a C string: an absolute path, or null (relative to the "." preopen)
	static var out:Ptr;
	static var dot:Ptr; // "."
	static var outLen:Int;

	public static inline function a32(p:Ptr):Int
		return p.toI64().toInt();

	public static inline function ofA32(x:Int):Ptr
		return new Ptr((x : I64) & ((((1 : I64) << 32) - 1)));

	@:hxmc.noGc public static function init() {
		var t = Mem.stack(16);
		// arguments
		WasiApi.args_sizes_get(a32(t), a32(t.add(4)));
		argc = Mem.getI32(t, 0);
		var bs = Mem.getI32(t, 4);
		var p32 = Heap.malloc(4 * argc + 4);
		var buf = Heap.malloc(bs + 1);
		WasiApi.args_get(a32(p32), a32(buf));
		argv = Heap.calloc(argc + 1, 8);
		for (i in 0...argc)
			Mem.setPtr(argv, 8 * i, ofA32(Mem.getI32(p32, 4 * i)));
		Mem.setI64(Mem.sym("rt_argc"), 0, argc);
		Mem.setPtr(Mem.sym("rt_argv"), 0, argv);
		Mem.setI64(Mem.sym("rt_nthreads"), 0, 1);
		// environment
		WasiApi.environ_sizes_get(a32(t), a32(t.add(4)));
		nenv = Mem.getI32(t, 0);
		bs = Mem.getI32(t, 4);
		p32 = Heap.malloc(4 * nenv + 4);
		buf = Heap.malloc(bs + 1);
		WasiApi.environ_get(a32(p32), a32(buf));
		env = Heap.calloc(nenv + 1, 8);
		for (i in 0...nenv)
			Mem.setPtr(env, 8 * i, ofA32(Mem.getI32(p32, 4 * i)));
		initPreopens(t);
		// the working directory: $PWD when a preopened directory covers it ("/",
		// or node's /c, /d, ... on Windows)
		var pwd = getenvC("PWD");
		cwd = Ptr.nil();
		if (!pwd.isNull() && Mem.getU8(pwd, 0) == "/".code && resolve(pwd, t) >= 0) cwd = Heap.strdup(pwd);
		dot = Heap.malloc(2);
		Mem.setI8(dot, 0, ".".code);
		Mem.setI8(dot, 1, 0);
		out = Heap.malloc(OUTBUF);
		outLen = 0;
	}

	// -D hxmc.wasm-gc: the module's system is its host's (hxmc.rt.gc.GcSys);
	// its WASI imports (a program's own calls, over this class's paths) see
	// the preopened directories, read when the first path is resolved, and
	// the host's working directory, asked for each relative path
	static inline function ready() {
		#if hxmc.wasm_gc
		if (pre.isNull()) {
			initPreopens(Mem.stack(16));
			dot = Heap.malloc(2);
			Mem.setI8(dot, 0, ".".code);
			Mem.setI8(dot, 1, 0);
		}
		#end
	}

	// the preopened directories: fd 3 on until EBADF (t: 8 bytes of scratch)
	@:hxmc.noGc static inline function initPreopens(t:Ptr) {
		pre = Heap.calloc(64, 16);
		npre = 0;
		var fd = 3;
		while (npre < 64 && WasiApi.fd_prestat_get(fd, a32(t)) == 0) {
			if (Mem.getU8(t, 0) == 0) {
				var n = Mem.getI32(t, 4);
				var name = Heap.malloc(n + 1);
				WasiApi.fd_prestat_dir_name(fd, a32(name), n);
				Mem.setI8(name, n, 0);
				// (node's WASI on Windows reports the names with backslashes)
				for (k in 0...n)
					if (Mem.getU8(name, k) == "\\".code) Mem.setI8(name, k, "/".code);
				// (a trailing slash is dropped, but not from "/")
				if (n > 1 && Mem.getU8(name, n - 1) == "/".code) Mem.setI8(name, n - 1, 0);
				Mem.setI32(pre, 16 * npre, fd);
				Mem.setPtr(pre, 16 * npre + 8, name);
				npre++;
			}
			fd++;
		}
	}

	@:hxmc.noGc static function findPre(lit:String):Int {
		for (i in 0...npre) {
			var n = Mem.getPtr(pre, 16 * i + 8);
			var ok = true;
			var len = hxmc.rt.Str.len(lit);
			for (k in 0...len)
				if (Mem.getU8(n, k) != hxmc.rt.Str.unit(lit, k)) ok = false;
			if (ok && Mem.getU8(n, len) == 0) return i;
		}
		return -1;
	}

	// the value of an environment variable (a C string in the environment block), or null
	@:hxmc.noGc public static function getenvC(lit:String):Ptr {
		var len = hxmc.rt.Str.len(lit);
		for (i in 0...nenv) {
			var e = Mem.getPtr(env, 8 * i);
			var ok = true;
			for (k in 0...len)
				if (Mem.getU8(e, k) != hxmc.rt.Str.unit(lit, k)) {
					ok = false;
					break;
				}
			if (ok && Mem.getU8(e, len) == "=".code) return e.add(len + 1);
		}
		return Ptr.nil();
	}

	@:hxmc.export("getenv") @:hxmc.noGc public static function getenv(name:Ptr):Ptr {
		var len = Heap.strlen(name).toInt();
		for (i in 0...nenv) {
			var e = Mem.getPtr(env, 8 * i);
			if (Heap.memcmp(e, name, len) == 0 && Mem.getU8(e, len) == "=".code) return e.add(len + 1);
		}
		return Ptr.nil();
	}

	// a decimal environment variable, or def
	@:hxmc.noGc public static function envInt(lit:String, def:Int):Int {
		var v = getenvC(lit);
		if (v.isNull()) return def;
		var n = 0, i = 0;
		while (Mem.getU8(v, i) >= "0".code && Mem.getU8(v, i) <= "9".code) {
			n = n * 10 + Mem.getU8(v, i) - "0".code;
			i++;
		}
		return n;
	}

	@:hxmc.noGc public static function argCount():Int
		return argc;

	@:hxmc.noGc public static function arg(i:Int):Ptr
		return Mem.getPtr(argv, 8 * i);

	@:hxmc.noGc public static function envCount():Int
		return nenv;

	@:hxmc.noGc public static function envAt(i:Int):Ptr
		return Mem.getPtr(env, 8 * i);

	// replaces the environment block (putEnv): n entries
	@:hxmc.noGc public static function setEnvBlock(e:Ptr, n:Int) {
		env = e;
		nenv = n;
	}

	// ---- output (fd 1 buffered)

	@:hxmc.noGc public static function writeRaw(fd:Int, p:Ptr, n:Int) {
		var io = Mem.stack(16);
		while (n > 0) {
			Mem.setI32(io, 0, a32(p));
			Mem.setI32(io, 4, n);
			if (WasiApi.fd_write(fd, a32(io), 1, a32(io.add(8))) != 0) return;
			var w = Mem.getI32(io, 8);
			if (w <= 0) return;
			p = p.add(w);
			n -= w;
		}
	}

	// the end of the program. The host's proc_exit throws (node's WASI, the
	// site's browser glue) and its exception crosses the try blocks of the
	// frames below: with no current handler, none of their pads takes it for
	// a Haxe exception (WasmGen: a pad handles its own handler only)
	@:hxmc.noGc public static function exit(code:Int):Void {
		flush();
		Mem.tlsSet("rt_hcur", Ptr.nil());
		WasiApi.proc_exit(code);
	}

	@:hxmc.noGc public static function flush() {
		if (outLen > 0) {
			var n = outLen;
			outLen = 0;
			writeRaw(1, out, n);
		}
	}

	@:hxmc.noGc public static function write(fd:Int, p:Ptr, n:Int) {
		if (fd != 1) {
			flush();
			writeRaw(fd, p, n);
			return;
		}
		if (outLen + n > OUTBUF) {
			flush();
			if (n > OUTBUF) {
				writeRaw(1, p, n);
				return;
			}
		}
		Wasm.memcpy(out.add(outLen), p, n);
		outLen += n;
	}

	// a string literal (Latin-1) without allocating
	@:hxmc.noGc public static function writeLit(fd:Int, lit:String) {
		var len = hxmc.rt.Str.len(lit);
		var b = Mem.stack(128);
		var i = 0;
		while (i < len) {
			var k = 0;
			while (k < 128 && i < len) {
				Mem.setI8(b, k, hxmc.rt.Str.unit(lit, i));
				k++;
				i++;
			}
			write(fd, b, k);
		}
	}

	@:hxmc.noGc public static function writeStr(fd:Int, s:String) {
		var u = hxmc.rt.Str.toUtf8(s);
		write(fd, u, Heap.strlen(u).toInt());
		Heap.free(u);
	}

	@:hxmc.noGc public static function writeInt(fd:Int, v:Int) {
		var b = Mem.stack(16);
		var k = 16;
		if (v == 0) {
			k--;
			Mem.setI8(b, k, "0".code);
		}
		while (v > 0) {
			k--;
			Mem.setI8(b, k, "0".code + v % 10);
			v = Std.int(v / 10);
		}
		write(fd, b.add(k), 16 - k);
	}

	// "gc: major <n>: <a> MB live, limit <b> MB, memory <m> MB" (RT_STATS)
	@:hxmc.noGc public static function statLine(lit:String, n:Int, a:Int, b:Int, m:Int) {
		writeLit(2, lit);
		writeInt(2, n);
		writeLit(2, ": ");
		writeInt(2, a);
		writeLit(2, " MB live, limit ");
		writeInt(2, b);
		writeLit(2, " MB, memory ");
		writeInt(2, m);
		writeLit(2, " MB\n");
	}

	@:hxmc.export("write") @:hxmc.noGc public static function posixWrite(fd:Int, p:Ptr, n:I64):I64 {
		write(fd, p, n.toInt());
		return n;
	}

	// ---- clocks

	@:hxmc.noGc public static function clockNs(id:Int):I64 {
		var t = Mem.stack(8);
		if (WasiApi.clock_time_get(id, 1000, a32(t)) != 0) return 0;
		return Mem.getI64(t, 0);
	}

	// ---- paths: (preopened fd, relative path) for a path; null when no preopen covers it

	// the absolute, normalized path of p (a C string) when the working
	// directory is known; else p normalized (relative)
	@:hxmc.noGc public static function absolute(p:Ptr):Ptr {
		ready();
		var n = Heap.strlen(p).toInt();
		var full:Ptr;
		#if hxmc.wasm_gc
		var cwd = Mem.getU8(p, 0) == "/".code ? Ptr.nil() : @:privateAccess hxmc.rt.Str.toUtf8(hxmc.rt.gc.GcSys.getCwd());
		#end
		if (Mem.getU8(p, 0) == "/".code || cwd.isNull()) {
			full = Heap.malloc(n + 1);
			Wasm.memcpy(full, p, n + 1);
		} else {
			var c = Heap.strlen(cwd).toInt();
			full = Heap.malloc(c + n + 2);
			Wasm.memcpy(full, cwd, c);
			Mem.setI8(full, c, "/".code);
			Wasm.memcpy(full.add(c + 1), p, n + 1);
		}
		#if hxmc.wasm_gc
		if (!cwd.isNull()) Heap.free(cwd);
		#end
		normalize(full);
		return full;
	}

	// removes ".", empty components and "x/.." in place
	@:hxmc.noGc static function normalize(p:Ptr) {
		var abs = Mem.getU8(p, 0) == "/".code;
		var r = 0, w = 0;
		var n = Heap.strlen(p).toInt();
		if (abs) {
			r = 1;
			w = 1;
		}
		var start = w;
		while (r < n) {
			var e = r;
			while (e < n && Mem.getU8(p, e) != "/".code)
				e++;
			var len = e - r;
			if (len == 0 || (len == 1 && Mem.getU8(p, r) == ".".code)) {} else if (len == 2 && Mem.getU8(p, r) == ".".code && Mem.getU8(p, r + 1) == ".".code
				&& w > start
				&& !(w - start >= 2 && Mem.getU8(p, w - 1) == ".".code && Mem.getU8(p, w - 2) == ".".code
					&& (w - 2 == start || Mem.getU8(p, w - 3) == "/".code))) {
				// back over the last component
				w--;
				while (w > start && Mem.getU8(p, w - 1) != "/".code)
					w--;
			} else {
				if (w > start && Mem.getU8(p, w - 1) != "/".code) {
					Mem.setI8(p, w, "/".code);
					w++;
				}
				for (k in 0...len)
					Mem.setI8(p, w + k, Mem.getU8(p, r + k));
				w += len;
			}
			r = e + 1;
		}
		if (w > start && Mem.getU8(p, w - 1) == "/".code) w--;
		if (w == 0) {
			Mem.setI8(p, 0, ".".code);
			w = 1;
		}
		Mem.setI8(p, w, 0);
	}

	// the preopened directory for an absolute or relative normalized path:
	// its fd; *rel (a pointer into p) the rest. -1: none
	@:hxmc.noGc public static function resolve(p:Ptr, rel:Ptr):Int {
		ready();
		var best = -1, bestLen = -1;
		var abs = Mem.getU8(p, 0) == "/".code;
		for (i in 0...npre) {
			var name = Mem.getPtr(pre, 16 * i + 8);
			var len = Heap.strlen(name).toInt();
			var nabs = Mem.getU8(name, 0) == "/".code;
			if (len == 1 && Mem.getU8(name, 0) == ".".code) {
				// "." holds the relative paths
				if (!abs && bestLen < 0) {
					best = i;
					bestLen = 0;
				}
				continue;
			}
			if (abs != nabs) continue;
			if (len == 1 && nabs) {
				if (len > bestLen) {
					best = i;
					bestLen = len;
				}
				continue;
			}
			if (Heap.memcmp(name, p, len) == 0 && (Mem.getU8(p, len) == 0 || Mem.getU8(p, len) == "/".code) && len > bestLen) {
				best = i;
				bestLen = len;
			}
		}
		if (best < 0) return -1;
		var r = p;
		if (abs || bestLen > 0) {
			r = p.add(bestLen);
			while (Mem.getU8(r, 0) == "/".code)
				r = r.add(1);
		} else if (Mem.getU8(r, 0) == ".".code && Mem.getU8(r, 1) == "/".code) r = r.add(2);
		if (Mem.getU8(r, 0) == 0) r = dot;
		Mem.setPtr(rel, 0, r);
		return Mem.getI32(pre, 16 * best);
	}

	// whether p (a C string) names a directory above a preopened one (/c above
	// node's /c/Users on Windows): those directories exist for the program
	@:hxmc.noGc public static function preopenAncestor(p:Ptr):Bool {
		var a = absolute(p);
		var alen = Heap.strlen(a).toInt();
		var found = false;
		if (Mem.getU8(a, 0) == "/".code)
			for (i in 0...npre) {
				var name = Mem.getPtr(pre, 16 * i + 8);
				var len = Heap.strlen(name).toInt();
				if (alen == 1 && len > 1 && Mem.getU8(name, 0) == "/".code) found = true;
				else if (len > alen && Heap.memcmp(name, a, alen) == 0 && Mem.getU8(name, alen) == "/".code) found = true;
			}
		Heap.free(a);
		return found;
	}

	@:hxmc.noGc public static function getCwd():Ptr
		return cwd;

	@:hxmc.noGc public static function setCwd(p:Ptr)
		cwd = p;
}
