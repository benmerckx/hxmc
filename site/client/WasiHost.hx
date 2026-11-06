import js.Syntax;
import js.lib.DataView;
import js.lib.Uint8Array;

// The browser's side of the playground's compiler: hxmc builds the port as a
// wasm32-wasi module (`make wasm`), whose only imports are WASI preview 1's
// (`wasi_snapshot_preview1`, hxmc/std/hxmc/rt/wasm/WasiApi.hx). In node and
// wasmtime the engine's WASI provides them; here this class does, from
// JavaScript: the arguments and environment, stdout and stderr to callbacks,
// the clocks (performance.now, Date.now), random bytes (crypto), and a file
// system in memory: "/" is the one preopened directory, holding the std the
// page loaded (shared by every instance, read only by convention) and the
// files of one compilation. What the compiler does not reach (sockets,
// processes, threads) is not imported by the module at all.

/** A file or a directory of the file system in memory. */
class VNode {
	public var dir:Null<Map<String, VNode>>;
	public var data:Uint8Array;
	public var size = 0;
	public var mtime:Float;

	public function new(isDir:Bool) {
		if (isDir) dir = new Map() else data = new Uint8Array(0);
		mtime = Date.now().getTime();
	}

	public static function file(bytes:Uint8Array):VNode {
		final n = new VNode(false);
		n.data = bytes;
		n.size = bytes.length;
		return n;
	}

	public function bytes():Uint8Array
		return data.subarray(0, size);

	/** room for `n` bytes */
	public function reserve(n:Int) {
		if (n <= data.length) return;
		final d = new Uint8Array(Std.int(Math.max(n, data.length * 2)));
		d.set(data.subarray(0, size));
		data = d;
	}
}

/** proc_exit: the end of the program, thrown through the module's frames */
class ExitStatus {
	public final status:Int;

	public function new(status:Int)
		this.status = status;
}

private typedef Open = {node:VNode, pos:Int, append:Bool, ?entries:Array<String>}

class WasiHost {
	// errno (WASI preview 1)
	static inline var ESUCCESS = 0;
	static inline var EBADF = 8;
	static inline var EEXIST = 20;
	static inline var EINVAL = 28;
	static inline var EISDIR = 31;
	static inline var ENOENT = 44;
	static inline var ENOSYS = 52;
	static inline var ENOTDIR = 54;
	static inline var ENOTEMPTY = 55;
	// filetype
	static inline var DIRECTORY = 3;
	static inline var REGULAR_FILE = 4;

	public final root:VNode;
	public var memory:Null<js.lib.webassembly.Memory>;

	final args:Array<String>;
	final env:Array<String>;
	/** where stdout and stderr go (replaced between the calls of a module that stays) */
	public var out:Int->Uint8Array->Void;
	final fds = new Map<Int, Open>();
	var nextFd = 4;
	static final encoder = new js.html.TextEncoder();
	static final decoder = new js.html.TextDecoder();

	/**
		`args` with the program's name first, `env` as NAME=value, `out` gets
		what the program writes to stdout (1) and stderr (2).
	**/
	public function new(root:VNode, args:Array<String>, env:Map<String, String>, out:Int->Uint8Array->Void) {
		this.root = root;
		this.args = args;
		this.env = [for (k => v in env) '$k=$v'];
		this.out = out;
		fds.set(3, {node: root, pos: 0, append: false});
	}

	/** the module's imports */
	public function imports():Dynamic {
		return {wasi_snapshot_preview1: {
			args_sizes_get: (n, size) -> sizes(args, n, size),
			args_get: (p, buf) -> strings(args, p, buf),
			environ_sizes_get: (n, size) -> sizes(env, n, size),
			environ_get: (p, buf) -> strings(env, p, buf),
			clock_time_get: clockTimeGet,
			fd_write: (fd, iovs, n, written) -> rw(true, fd, iovs, n, written),
			fd_read: (fd, iovs, n, read) -> rw(false, fd, iovs, n, read),
			fd_close: fdClose,
			fd_seek: fdSeek,
			fd_tell: (fd, at) -> fdSeek(fd, Syntax.code("0n"), 1, at),
			fd_filestat_get: (fd, buf) -> {
				final o = fds.get(fd);
				o == null ? EBADF : stat(o.node, buf);
			},
			fd_fdstat_get: fdFdstatGet,
			fd_prestat_get: (fd, buf) -> {
				if (fd != 3) return EBADF;
				view().setUint8(buf, 0); // a directory
				view().setUint32(buf + 4, 1, true); // "/"
				ESUCCESS;
			},
			fd_prestat_dir_name: (fd, p, len) -> {
				if (fd != 3) return EBADF;
				if (len >= 1) view().setUint8(p, "/".code);
				ESUCCESS;
			},
			fd_readdir: fdReaddir,
			path_open: pathOpen,
			path_filestat_get: (fd, flags, p, len, buf) -> {
				final r = lookup(fd, p, len);
				r.node == null ? r.err : stat(r.node, buf);
			},
			path_create_directory: (fd, p, len) -> {
				final r = lookup(fd, p, len);
				if (r.node != null) return EEXIST;
				if (r.parent == null) return r.err;
				r.parent.dir.set(r.name, new VNode(true));
				ESUCCESS;
			},
			path_remove_directory: (fd, p, len) -> {
				final r = lookup(fd, p, len);
				if (r.node == null) return r.err;
				if (r.node.dir == null) return ENOTDIR;
				if (r.node.dir.keys().hasNext()) return ENOTEMPTY;
				r.parent.dir.remove(r.name);
				ESUCCESS;
			},
			path_unlink_file: (fd, p, len) -> {
				final r = lookup(fd, p, len);
				if (r.node == null) return r.err;
				if (r.node.dir != null) return EISDIR;
				r.parent.dir.remove(r.name);
				ESUCCESS;
			},
			path_rename: (fd, p, len, fd2, p2, len2) -> {
				final a = lookup(fd, p, len), b = lookup(fd2, p2, len2);
				if (a.node == null) return a.err;
				if (b.parent == null) return b.err;
				if (b.node != null && b.node.dir != null && b.node.dir.keys().hasNext()) return ENOTEMPTY;
				a.parent.dir.remove(a.name);
				b.parent.dir.set(b.name, a.node);
				ESUCCESS;
			},
			poll_oneoff: pollOneoff,
			random_get: (p, len) -> {
				var at = 0;
				while (at < len) {
					final n = Std.int(Math.min(65536, len - at));
					js.Lib.global.crypto.getRandomValues(new Uint8Array(memory.buffer, p + at, n));
					at += n;
				}
				ESUCCESS;
			},
			proc_exit: (code:Int) -> throw new ExitStatus(code),
		}};
	}

	// ---- files of the file system

	/** the file at an absolute path, or null */
	public function readFile(path:String):Null<Uint8Array> {
		var n = root;
		for (part in path.split("/"))
			if (part != "") {
				if (n.dir == null || !n.dir.exists(part)) return null;
				n = n.dir.get(part);
			}
		return n.dir == null ? n.bytes() : null;
	}

	/** writes a file at an absolute path, with the directories it needs */
	public function writeFile(path:String, bytes:Uint8Array) {
		final parts = [for (p in path.split("/")) if (p != "") p];
		final name = parts.pop();
		var n = root;
		for (part in parts) {
			if (!n.dir.exists(part)) n.dir.set(part, new VNode(true));
			n = n.dir.get(part);
		}
		n.dir.set(name, VNode.file(bytes));
	}

	// ---- memory

	inline function view():DataView
		return new DataView(memory.buffer);

	function setU64(at:Int, v:Float) {
		final dv = view();
		dv.setUint32(at, Std.int(v % 4294967296) >>> 0, true);
		dv.setUint32(at + 4, Std.int(v / 4294967296) >>> 0, true);
	}

	function str(p:Int, len:Int):String
		return decoder.decode(new Uint8Array(memory.buffer, p, len));

	static inline function num(big:Dynamic):Float
		return Syntax.code("Number({0})", big);

	// ---- arguments and environment

	function sizes(list:Array<String>, n:Int, size:Int):Int {
		var total = 0;
		for (s in list)
			total += encoder.encode(s).length + 1;
		view().setUint32(n, list.length, true);
		view().setUint32(size, total, true);
		return ESUCCESS;
	}

	function strings(list:Array<String>, p:Int, buf:Int):Int {
		final mem = new Uint8Array(memory.buffer);
		for (k in 0...list.length) {
			final b = encoder.encode(list[k]);
			view().setUint32(p + 4 * k, buf, true);
			mem.set(b, buf);
			mem[buf + b.length] = 0;
			buf += b.length + 1;
		}
		return ESUCCESS;
	}

	// ---- clocks and waiting

	function now(id:Int):Float {
		// realtime 0; monotonic 1, process and thread CPU time 2, 3 (as the monotonic clock)
		return id == 0 ? Date.now().getTime() * 1e6 : js.Lib.global.performance.now() * 1e6;
	}

	function clockTimeGet(id:Int, precision:Dynamic, at:Int):Int {
		if (id < 0 || id > 3) return EINVAL;
		setU64(at, Math.ffloor(now(id)));
		return ESUCCESS;
	}

	// clock subscriptions only (Sys.sleep): a worker may block, so it waits
	function pollOneoff(subs:Int, events:Int, n:Int, nevents:Int):Int {
		final dv = view();
		for (k in 0...n) {
			final s = subs + 48 * k;
			if (dv.getUint8(s + 8) != 0) return ENOSYS;
			final id = dv.getUint32(s + 16, true);
			final timeout = dv.getUint32(s + 24, true) + dv.getUint32(s + 28, true) * 4294967296.0;
			final absolute = (dv.getUint16(s + 40, true) & 1) != 0;
			final end = absolute ? timeout : now(id) + timeout;
			while (now(id) < end) {}
			final e = events + 32 * k;
			new Uint8Array(memory.buffer, e, 32).fill(0);
			dv.setUint32(e, dv.getUint32(s, true), true);
			dv.setUint32(e + 4, dv.getUint32(s + 4, true), true);
		}
		dv.setUint32(nevents, n, true);
		return ESUCCESS;
	}

	// ---- file descriptors

	function rw(write:Bool, fd:Int, iovs:Int, n:Int, done:Int):Int {
		final dv = view();
		var total = 0;
		final o = fds.get(fd);
		if (o == null && fd > 2) return EBADF;
		if (o != null && o.node.dir != null) return EISDIR;
		for (k in 0...n) {
			final p = dv.getUint32(iovs + 8 * k, true), len = dv.getUint32(iovs + 8 * k + 4, true);
			if (write) {
				final b = new Uint8Array(memory.buffer, p, len);
				if (fd == 1 || fd == 2) out(fd, b.slice()) else if (fd == 0) return EBADF else {
					if (o.append) o.pos = o.node.size;
					o.node.reserve(o.pos + len);
					o.node.data.set(b, o.pos);
					o.pos += len;
					if (o.pos > o.node.size) o.node.size = o.pos;
					o.node.mtime = Date.now().getTime();
				}
				total += len;
			} else {
				// (stdin is empty)
				if (fd <= 2) break;
				final m = Std.int(Math.max(0, Math.min(len, o.node.size - o.pos)));
				new Uint8Array(memory.buffer, p, m).set(o.node.data.subarray(o.pos, o.pos + m));
				o.pos += m;
				total += m;
				if (m < len) break;
			}
		}
		view().setUint32(done, total, true);
		return ESUCCESS;
	}

	function fdClose(fd:Int):Int {
		if (fd == 3 || !fds.exists(fd)) return fd <= 3 ? ESUCCESS : EBADF;
		fds.remove(fd);
		return ESUCCESS;
	}

	function fdSeek(fd:Int, offset:Dynamic, whence:Int, at:Int):Int {
		final o = fds.get(fd);
		if (o == null || fd == 3) return EBADF;
		final base = switch whence {
			case 0: 0;
			case 1: o.pos;
			case 2: o.node.size;
			case _: return EINVAL;
		}
		final p = base + Std.int(num(offset));
		if (p < 0) return EINVAL;
		o.pos = p;
		setU64(at, p);
		return ESUCCESS;
	}

	function fdFdstatGet(fd:Int, buf:Int):Int {
		final o = fds.get(fd);
		if (o == null && fd > 2) return EBADF;
		final dv = view();
		new Uint8Array(memory.buffer, buf, 24).fill(0);
		// stdio: a character device (2)
		dv.setUint8(buf, o == null ? 2 : o.node.dir != null ? DIRECTORY : REGULAR_FILE);
		// every right, handed down too
		for (k in 0...4)
			dv.setUint32(buf + 8 + 4 * k, 0xFFFFFFFF, true);
		return ESUCCESS;
	}

	function stat(n:VNode, buf:Int):Int {
		final dv = view();
		new Uint8Array(memory.buffer, buf, 64).fill(0);
		dv.setUint8(buf + 16, n.dir != null ? DIRECTORY : REGULAR_FILE);
		setU64(buf + 24, 1);
		setU64(buf + 32, n.dir != null ? 0 : n.size);
		for (t in [40, 48, 56])
			setU64(buf + t, n.mtime * 1e6);
		return ESUCCESS;
	}

	// the entries ".", ".." and the names in order, from the cookie's index
	function fdReaddir(fd:Int, buf:Int, len:Int, cookie:Dynamic, used:Int):Int {
		final o = fds.get(fd);
		if (o == null) return EBADF;
		if (o.node.dir == null) return ENOTDIR;
		if (o.entries == null) {
			final names = [for (k in o.node.dir.keys()) k];
			names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			o.entries = [".", ".."].concat(names);
		}
		final mem = new Uint8Array(memory.buffer);
		final dv = view();
		var at = 0;
		var k = Std.int(num(cookie));
		while (k < o.entries.length && at < len) {
			final name = encoder.encode(o.entries[k]);
			final child = k < 2 ? o.node : o.node.dir.get(o.entries[k]);
			final e = new Uint8Array(24 + name.length);
			final ev = new DataView(e.buffer);
			ev.setUint32(0, k + 1, true);
			ev.setUint32(8, k + 1, true);
			ev.setUint32(16, name.length, true);
			ev.setUint8(20, child.dir != null ? DIRECTORY : REGULAR_FILE);
			e.set(name, 24);
			// the last entry may be cut: the caller reads on from its cookie
			final m = Std.int(Math.min(e.length, len - at));
			mem.set(e.subarray(0, m), buf + at);
			at += m;
			k++;
		}
		dv.setUint32(used, at, true);
		return ESUCCESS;
	}

	// a path relative to a directory: its node (null: none), and its parent
	// directory and name when that exists
	function lookup(fd:Int, p:Int, len:Int):{node:Null<VNode>, parent:Null<VNode>, name:String, err:Int} {
		final o = fds.get(fd);
		if (o == null) return {node: null, parent: null, name: "", err: EBADF};
		final stack = [o.node];
		final parts = [for (s in str(p, len).split("/")) if (s != "" && s != ".") s];
		for (k in 0...parts.length) {
			final part = parts[k];
			final cur = stack[stack.length - 1];
			if (cur.dir == null) return {node: null, parent: null, name: part, err: ENOTDIR};
			if (part == "..") {
				if (stack.length > 1) stack.pop();
				continue;
			}
			final next = cur.dir.get(part);
			if (next == null)
				return k == parts.length - 1 ? {node: null, parent: cur, name: part, err: ENOENT} : {node: null, parent: null, name: part, err: ENOENT};
			if (k == parts.length - 1) return {node: next, parent: cur, name: part, err: ESUCCESS};
			stack.push(next);
		}
		return {node: stack[stack.length - 1], parent: stack.length > 1 ? stack[stack.length - 2] : null, name: "", err: ESUCCESS};
	}

	function pathOpen(fd:Int, dirflags:Int, p:Int, len:Int, oflags:Int, rightsBase:Dynamic, rightsInheriting:Dynamic, fdflags:Int, at:Int):Int {
		final r = lookup(fd, p, len);
		var n = r.node;
		// oflags: CREAT 1, DIRECTORY 2, EXCL 4, TRUNC 8; fdflags: APPEND 1
		if (n == null) {
			if ((oflags & 1) == 0 || r.parent == null) return r.err;
			n = new VNode(false);
			r.parent.dir.set(r.name, n);
		} else if ((oflags & 4) != 0) return EEXIST;
		if ((oflags & 2) != 0 && n.dir == null) return ENOTDIR;
		if ((oflags & 8) != 0) {
			if (n.dir != null) return EISDIR;
			n.size = 0;
		}
		final id = nextFd++;
		fds.set(id, {node: n, pos: 0, append: (fdflags & 1) != 0});
		view().setUint32(at, id, true);
		return ESUCCESS;
	}
}
