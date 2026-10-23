package hxmc.rt;

import haxe.io.Bytes;
import hxmc.I64;
import hxmc.NativeThread;
import hxmc.rt.C;
import hxmc.rt.UvLayouts as L;
import hxmc.unsafe.*;

// libuv behind hxmc.NativeUv (the Eval natives of eval.luv.*,
// src/macros/eval/EvalLuv.hx), standing for the OCaml luv library; once C
// (rt_uv.c), now Haxe calling libuv directly (docs/plans/lowlevel.md). libuv
// itself stays the prebuilt uv.o, linked when a program uses it.
//
// Loops, handles, requests and directories are integer ids into a table of
// C objects. Functions returning Int give a negative libuv error code on
// failure unless noted; functions returning an object give null on failure
// with the code in `lastError()`. 64-bit results are read with i64Hi/i64Lo.
// libuv invokes its callbacks from uv_run only: uv_run is a C call in a safe
// region (other threads collect while it waits), and its callbacks
// (@:hxmc.callback, through the compiler's wrapper that leaves the safe
// region) report events to the port's dispatcher, kept per thread for the
// duration of loopRun: dispatch(id, event, int, value). Buffers stay in the
// GC heap on the Haxe side: data is copied into C memory for writes and
// copied out of C memory after reads. Socket addresses are Bytes holding a
// struct sockaddr_storage. Nothing is finalized: requests are freed when the
// port releases them, handles when their close completes.
//
// The C layouts and constants of libuv and of the C library differ per
// target (error codes, flags, struct fields): UvLayouts, generated from the
// headers by hxmc/deps/Layouts.hx.
class Uv {
	// ---- object table (id 0 is unused): chunks that never move, so lookups
	// need no lock (adding one does)
	static inline var OBJ_CHUNK = 1024;
	static inline var OBJ_CHUNKS = 65536;

	// the table's state, malloc'ed on first use: the count (atomic), a spin
	// lock (adding), then the chunk pointers
	static var table:Ptr;

	@:hxmc.threadLocal static var lastErr:Int;
	@:hxmc.threadLocal static var i64Out:I64;
	@:hxmc.threadLocal static var allocSizeV:Int;

	// the dispatcher of the loop running on this thread (a thread-local value of
	// the runtime: rooted with its thread)
	static var dispatcherTls:Int = NativeThread.tlsNew();

	static inline var T_COUNT = 0;
	static inline var T_LOCK = 4;
	static inline var T_CHUNKS = 8;

	@:hxmc.noGc static function lock(p:Ptr) {
		while (Atomic.cas32(p, 0, 1) != 0)
			Threads.current(); // (spins: held for a few instructions)
	}

	@:hxmc.noGc static function unlock(p:Ptr)
		Atomic.store32(p, 0);

	static function objAdd(p:Ptr):Int {
		var t = state();
		lock(t.add(T_LOCK));
		var id = Mem.getI32(t, T_COUNT);
		if ((id >> 10) >= OBJ_CHUNKS) {
			unlock(t.add(T_LOCK));
			Rt.rt_throw("eval.luv: too many handles");
		}
		var slot = T_CHUNKS + 8 * (id >> 10);
		var chunk = Mem.getPtr(t, slot);
		if (chunk.isNull()) {
			chunk = LibC.malloc(8 * OBJ_CHUNK);
			LibC.memset(chunk, 0, 8 * OBJ_CHUNK);
			Mem.setPtr(t, slot, chunk);
		}
		Mem.setPtr(chunk, 8 * (id & 1023), p);
		Atomic.store32(t, id + 1);
		unlock(t.add(T_LOCK));
		return id;
	}

	@:hxmc.noGc static function slotOf(id:Int):Ptr {
		var t = state();
		return Mem.getPtr(t, T_CHUNKS + 8 * (id >> 10)).add(8 * (id & 1023));
	}

	static function objGet(id:Int):Ptr {
		var t = state();
		var n = Atomic.load32(t);
		var p = id > 0 && id < n ? Mem.getPtr(slotOf(id), 0) : Ptr.nil();
		if (p.isNull()) Rt.rt_throw("eval.luv: invalid or closed handle");
		return p;
	}

	@:hxmc.noGc static function objClear(id:Int)
		Mem.setPtr(slotOf(id), 0, Ptr.nil());

	// (once: a race between two threads' first calls leaks one table)
	@:hxmc.noGc static function state():Ptr {
		if (table.isNull()) {
			var size:I64 = T_CHUNKS + 8 * OBJ_CHUNKS;
			var t = LibC.malloc(size);
			LibC.memset(t, 0, size);
			Mem.setI32(t, T_COUNT, 1);
			table = t;
		}
		return table;
	}

	public static function available():Bool
		return true;

	public static function lastError():Int
		return lastErr;

	public static function i64Hi():Int
		return (i64Out >> 32).toInt();

	public static function i64Lo():Int
		return i64Out.toInt();

	// ---- C data <-> Haxe values

	static inline function data(b:Bytes):Ptr
		return Mem.addr(b.getData());

	// a NUL-terminated copy of a Bytes in the arena (null for null)
	static function bytesZ(a:Arena, b:Null<Bytes>):CString
		return b == null ? Ptr.nil() : a.copyBytesZ(b);

	static function bytesOf(p:Ptr, n:Int):Bytes {
		var b = Bytes.alloc(n);
		if (n > 0) LibC.memcpy(data(b), p, (n : I64));
		return b;
	}

	static function bytesOfC(s:Ptr):Null<Bytes>
		return s.isNull() ? null : bytesOf(s, LibC.strlen(s).toInt());

	static function strOfC(s:Ptr):String
		return Str.ofUtf8(s, LibC.strlen(s).toInt());

	// a struct sockaddr_storage as Bytes (len bytes of s, the rest zero)
	static function sockaddrBytes(s:Ptr, len:Int):Bytes {
		var b = Bytes.alloc(L.SOCKADDR_STORAGE_SIZE);
		if (!s.isNull()) LibC.memcpy(data(b), s, (len : I64));
		return b;
	}

	static inline function nullable(b:Null<Bytes>):Ptr
		return b == null ? Ptr.nil() : data(b);

	// a C long (32 bits on Windows)
	@:hxmc.noGc static inline function getLong(p:Ptr, off:Int):I64
		return L.LONG_SIZE == 4 ? (Mem.getI32(p, off) : I64) : Mem.getI64(p, off);

	// ---- errors: luv's Error.t, in evalLuv.ml's encode_uv_error order

	// Error.from_c: unknown codes are `UNKNOWN (71)
	public static function errIndex(code:Int):Int {
		for (i in 0...82)
			if (i != 24 && L.uvError(i) == code) return i;
		return 71;
	}

	public static function errCode(index:Int):Int
		return index >= 0 && index < 82 ? L.uvError(index) : L.UV_UNKNOWN;

	// Error.strerror / err_name: the _r variants into a 256-byte buffer
	public static function strerror(code:Int):String {
		var buf = Mem.stack(256);
		U.uv_strerror_r(code, buf, 256);
		return strOfC(buf);
	}

	public static function errName(code:Int):String {
		var buf = Mem.stack(256);
		U.uv_err_name_r(code, buf, 256);
		return strOfC(buf);
	}

	public static function translateSysError(e:Int):Int
		return U.uv_translate_sys_error(e);

	// constants: group, index -> C value (luv's to_c tables)
	public static function constant(group:Int, index:Int):Int {
		return switch group {
			case 10: // dirent types: UNKNOWN FILE DIR LINK FIFO SOCKET CHAR BLOCK (C value -> index)
				var r = 0;
				for (i in 0...8)
					if (L.constant(10, i) == index) {
						r = i;
						break;
					}
				r;
			case 2: L.constant(2, index & 3);
			case _: L.constant(group, index);
		}
	}

	public static function versionString():String
		return strOfC(U.uv_version_string());

	public static function versionSuffix():String
		return L.UV_VERSION_SUFFIX;

	// ---- dispatching events to the port (during loopRun)

	static inline var EV_CLOSE = 0;
	static inline var EV_CB = 1;
	static inline var EV_REQ = 2;
	static inline var EV_CONNECTION = 3;
	static inline var EV_ALLOC = 4;
	static inline var EV_READ = 5;
	static inline var EV_EXIT = 6;
	static inline var EV_UDP_RECV = 7;
	static inline var EV_FS_EVENT = 8;
	static inline var EV_FS_POLL = 9;

	static function dispatch(id:Int, ev:Int, a:Int, b:Dynamic) {
		var f:(Int, Int, Int, Dynamic) -> Void = NativeThread.tlsGet(dispatcherTls);
		if (f != null) f(id, ev, a, b);
	}

	// ---- loops: an id stands for a uv_loop_t pointer

	static var defaultLoopId:Int;
	static var loopLock:Ptr;

	static inline function loop(id:Int):Ptr
		return Mem.getPtr(objGet(id), 0);

	public static function loopDefault():Int {
		if (loopLock.isNull()) {
			var l = LibC.malloc(8);
			Mem.setI64(l, 0, 0);
			loopLock = l;
		}
		lock(loopLock);
		if (defaultLoopId == 0) {
			var l = LibC.malloc(8);
			Mem.setPtr(l, 0, U.uv_default_loop());
			defaultLoopId = objAdd(l);
		}
		var id = defaultLoopId;
		unlock(loopLock);
		return id;
	}

	public static function loopInit():Int {
		var lp = LibC.malloc(U.uv_loop_size());
		var r = U.uv_loop_init(lp);
		if (r < 0) {
			LibC.free(lp);
			return r;
		}
		var l = LibC.malloc(8);
		Mem.setPtr(l, 0, lp);
		return objAdd(l);
	}

	// uv_run in a safe region: other threads run and collect while it waits;
	// its callbacks leave the safe region for their Haxe code
	public static function loopRun(id:Int, mode:Int, dispatcher:(Int, Int, Int, Dynamic) -> Void):Bool {
		var lp = loop(id);
		var saved = NativeThread.tlsGet(dispatcherTls);
		NativeThread.tlsSet(dispatcherTls, dispatcher);
		var r = UB.uv_run(lp, mode == 0 ? L.UV_RUN_DEFAULT : mode == 1 ? L.UV_RUN_ONCE : L.UV_RUN_NOWAIT);
		NativeThread.tlsSet(dispatcherTls, saved);
		return r != 0;
	}

	public static function loopStop(id:Int):Void
		U.uv_stop(loop(id));

	public static function loopClose(id:Int):Int
		return U.uv_loop_close(loop(id));

	public static function loopAlive(id:Int):Bool
		return U.uv_loop_alive(loop(id)) != 0;

	// i64
	public static function loopNow(id:Int):Void
		i64Out = U.uv_now(loop(id));

	public static function loopUpdateTime(id:Int):Void
		U.uv_update_time(loop(id));

	public static function libraryShutdown():Void
		U.uv_library_shutdown();

	// i64
	public static function metricsIdleTime(id:Int):Void
		i64Out = U.uv_metrics_idle_time(loop(id));

	// ---- handles: hx_h, the id, the kind, the memory of the last allocation
	// for reads (rbuf, rlen), then the uv handle

	static inline var HK_IDLE = 0;
	static inline var HK_PREPARE = 1;
	static inline var HK_CHECK = 2;
	static inline var HK_TIMER = 3;
	static inline var HK_ASYNC = 4;
	static inline var HK_TCP = 5;
	static inline var HK_UDP = 6;
	static inline var HK_PIPE = 7;
	static inline var HK_TTY = 8;
	static inline var HK_SIGNAL = 9;
	static inline var HK_PROCESS = 10;
	static inline var HK_FS_EVENT = 11;
	static inline var HK_FS_POLL = 12;

	static inline var H_ID = 0;
	static inline var H_KIND = 4;
	static inline var H_RBUF = 8;
	static inline var H_RLEN = 16;
	static inline var H_UV = 24;

	// the largest uv handle (uv_handle_size of each type), once
	static var handleSize:Int;

	@:hxmc.noGc static function handleBytes():Int {
		if (handleSize == 0) {
			var m = 0;
			for (t in 1...L.UV_HANDLE_TYPE_MAX) {
				var s = U.uv_handle_size(t).toInt();
				if (s > m) m = s;
			}
			handleSize = m;
		}
		return H_UV + handleSize;
	}

	// the uv handle of a handle id, and the hx_h of a uv handle
	static inline function H(id:Int):Ptr
		return objGet(id);

	static inline function uvh(id:Int):Ptr
		return objGet(id).add(H_UV);

	@:hxmc.noGc static inline function hx(uh:Ptr):Ptr
		return uh.add(-H_UV);

	@:hxmc.noGc static inline function hid(uh:Ptr):Int
		return Mem.getI32(uh, -H_UV + H_ID);

	static function newHandle(kind:Int):Ptr {
		var n = handleBytes();
		var h = LibC.malloc((n : I64));
		LibC.memset(h, 0, (n : I64));
		Mem.setI32(h, H_KIND, kind);
		Mem.setI32(h, H_ID, objAdd(h));
		return h;
	}

	@:hxmc.noGc static function freeHandle(h:Ptr) {
		objClear(Mem.getI32(h, H_ID));
		LibC.free(Mem.getPtr(h, H_RBUF));
		LibC.free(h);
	}

	// init: returns the handle id, or a negative error. arg: a domain (tcp, udp),
	// ipc (pipe), fd (tty), udp flags
	public static function handleInit(kind:Int, loopId:Int, arg:Int, arg2:Int):Int {
		var lp = loop(loopId);
		var h = newHandle(kind);
		var u = h.add(H_UV);
		var r = switch kind {
			case HK_IDLE: U.uv_idle_init(lp, u);
			case HK_PREPARE: U.uv_prepare_init(lp, u);
			case HK_CHECK: U.uv_check_init(lp, u);
			case HK_TIMER: U.uv_timer_init(lp, u);
			case HK_ASYNC: U.uv_async_init(lp, u, Callback.addr(asyncCb));
			case HK_TCP: arg < 0 ? U.uv_tcp_init(lp, u) : U.uv_tcp_init_ex(lp, u, arg);
			case HK_UDP: U.uv_udp_init_ex(lp, u, (arg < 0 ? L.AF_UNSPEC : arg) | arg2);
			case HK_PIPE: U.uv_pipe_init(lp, u, arg);
			case HK_TTY: U.uv_tty_init(lp, u, arg, 0);
			case HK_SIGNAL: U.uv_signal_init(lp, u);
			case HK_FS_EVENT: U.uv_fs_event_init(lp, u);
			case HK_FS_POLL: U.uv_fs_poll_init(lp, u);
			case _: L.UV_EINVAL;
		}
		U.uv_handle_set_data(u, h);
		if (r < 0) {
			freeHandle(h);
			return r;
		}
		return Mem.getI32(h, H_ID);
	}

	@:hxmc.callback static function closeCb(uh:Ptr):Void {
		var id = hid(uh);
		freeHandle(hx(uh));
		dispatch(id, EV_CLOSE, 0, null);
	}

	@:hxmc.callback @:hxmc.noGc static function closeSilentCb(uh:Ptr):Void
		freeHandle(hx(uh));

	// Handle.close: nothing when already closing
	// false: already closing
	public static function handleClose(id:Int):Bool {
		var u = uvh(id);
		if (U.uv_is_closing(u) != 0) return false;
		U.uv_close(u, Callback.addr(closeCb));
		return true;
	}

	public static function handleIsActive(id:Int):Bool
		return U.uv_is_active(uvh(id)) != 0;

	public static function handleIsClosing(id:Int):Bool
		return U.uv_is_closing(uvh(id)) != 0;

	public static function handleRef(id:Int):Void
		U.uv_ref(uvh(id));

	public static function handleUnref(id:Int):Void
		U.uv_unref(uvh(id));

	public static function handleHasRef(id:Int):Bool
		return U.uv_has_ref(uvh(id)) != 0;

	// send/recv buffer size: size 0 reads it
	// size 0: get
	public static function bufferSize(id:Int, send:Bool, size:Int):Int {
		var v:Ptr<Int32> = Mem.stack(16);
		v.value = size;
		var r = send ? U.uv_send_buffer_size(uvh(id), v) : U.uv_recv_buffer_size(uvh(id), v);
		return r < 0 ? r : v.value;
	}

	// ---- idle, prepare, check, timer, async, signal

	@:hxmc.callback static function watcherCb(w:Ptr):Void
		dispatch(hid(w), EV_CB, 0, null);

	@:hxmc.callback static function asyncCb(w:Ptr):Void
		dispatch(hid(w), EV_CB, 0, null);

	@:hxmc.callback static function signalCb(w:Ptr, signum:Int):Void
		dispatch(hid(w), EV_CB, signum, null);

	public static function watcherStart(id:Int):Int {
		var h = H(id);
		var u = h.add(H_UV);
		return switch Mem.getI32(h, H_KIND) {
			case HK_IDLE: U.uv_idle_start(u, Callback.addr(watcherCb));
			case HK_PREPARE: U.uv_prepare_start(u, Callback.addr(watcherCb));
			case _: U.uv_check_start(u, Callback.addr(watcherCb));
		}
	}

	public static function watcherStop(id:Int):Int {
		var h = H(id);
		var u = h.add(H_UV);
		return switch Mem.getI32(h, H_KIND) {
			case HK_IDLE: U.uv_idle_stop(u);
			case HK_PREPARE: U.uv_prepare_stop(u);
			case _: U.uv_check_stop(u);
		}
	}

	static inline function u32(v:Int):I64
		return ((v : I64) << 32) >>> 32; // (& 0xFFFFFFFF would keep the sign: the literal is the Int -1)

	public static function timerStart(id:Int, timeout:Int, repeat:Int):Int
		return U.uv_timer_start(uvh(id), Callback.addr(watcherCb), u32(timeout), u32(repeat));

	public static function timerStop(id:Int):Int
		return U.uv_timer_stop(uvh(id));

	public static function timerAgain(id:Int):Int
		return U.uv_timer_again(uvh(id));

	public static function timerSetRepeat(id:Int, repeat:Int):Void
		U.uv_timer_set_repeat(uvh(id), u32(repeat));

	public static function timerGetRepeat(id:Int):Int
		return U.uv_timer_get_repeat(uvh(id)).toInt();

	public static function timerGetDueIn(id:Int):Int
		return U.uv_timer_get_due_in(uvh(id)).toInt();

	public static function asyncSend(id:Int):Int
		return U.uv_async_send(uvh(id));

	public static function signalStart(id:Int, signum:Int, oneshot:Bool):Int {
		var u = uvh(id);
		return oneshot ? U.uv_signal_start_oneshot(u, Callback.addr(signalCb), signum) : U.uv_signal_start(u, Callback.addr(signalCb), signum);
	}

	public static function signalStop(id:Int):Int
		return U.uv_signal_stop(uvh(id));

	public static function signalSignum(id:Int):Int
		return Mem.getI32(uvh(id), L.SIGNAL_SIGNUM);

	// ---- requests: hx_r, the id, copied data (writes) or data to copy out
	// (reads) and its length, the uv_buf_t array, the getaddrinfo result,
	// readdir's entries and directory, then the uv request

	static inline var R_ID = 0;
	static inline var R_SCRATCH = 8;
	static inline var R_SCRATCH_LEN = 16;
	static inline var R_BUFS = 24;
	static inline var R_AI = 32;
	static inline var R_DIRENTS = 40;
	static inline var R_DIR_ID = 48;
	static inline var R_UV = 56;

	static var reqSize:Int;

	@:hxmc.noGc static function reqBytes():Int {
		if (reqSize == 0) {
			var m = 0;
			for (t in 1...L.UV_REQ_TYPE_MAX) {
				var s = U.uv_req_size(t).toInt();
				if (s > m) m = s;
			}
			reqSize = m;
		}
		return R_UV + reqSize;
	}

	static inline function R(id:Int):Ptr
		return objGet(id);

	static inline function uvr(id:Int):Ptr
		return objGet(id).add(R_UV);

	@:hxmc.noGc static inline function rid(req:Ptr):Int
		return Mem.getI32(req, -R_UV + R_ID);

	public static function reqNew():Int {
		var n = reqBytes();
		var r = LibC.malloc((n : I64));
		LibC.memset(r, 0, (n : I64));
		U.uv_req_set_data(r.add(R_UV), r);
		var id = objAdd(r);
		Mem.setI32(r, R_ID, id);
		return id;
	}

	@:hxmc.noGc static function reqClear(r:Ptr) {
		LibC.free(Mem.getPtr(r, R_SCRATCH));
		Mem.setPtr(r, R_SCRATCH, Ptr.nil());
		Mem.setI64(r, R_SCRATCH_LEN, 0);
		LibC.free(Mem.getPtr(r, R_BUFS));
		Mem.setPtr(r, R_BUFS, Ptr.nil());
		var ai = Mem.getPtr(r, R_AI);
		if (!ai.isNull()) U.uv_freeaddrinfo(ai);
		Mem.setPtr(r, R_AI, Ptr.nil());
	}

	public static function reqFree(id:Int):Void {
		var r = R(id);
		reqClear(r);
		objClear(id);
		LibC.free(Mem.getPtr(r, R_DIRENTS));
		LibC.free(r);
	}

	public static function reqCancel(id:Int):Int
		return U.uv_cancel(uvr(id));

	@:hxmc.callback static function statusCb(req:Ptr, status:Int):Void
		dispatch(rid(req), EV_REQ, status, null);

	@:hxmc.callback static function randomCb(req:Ptr, status:Int, buf:Ptr, len:I64):Void
		dispatch(rid(req), EV_REQ, status, null);

	// a uv_buf_t (Windows: ULONG len, then base; elsewhere base, then size_t len)
	@:hxmc.noGc static function setBuf(buf:Ptr, base:Ptr, len:Int) {
		Mem.setPtr(buf, L.UV_BUF_BASE, base);
		if (L.UV_BUF_LEN_SIZE == 4) Mem.setI32(buf, L.UV_BUF_LEN, len) else Mem.setI64(buf, L.UV_BUF_LEN, u32(len));
	}

	// copies `data` into the request's scratch and splits it into `sizes`
	// buffers (reads: data null, the sizes' total); the number of buffers
	static function reqBufs(r:Ptr, d:Null<Bytes>, sizes:Null<Array<Int>>):Int {
		var n = sizes != null ? sizes.length : 0;
		var total = 0;
		if (d != null) total = d.length else for (i in 0...n) total += sizes[i];
		reqClear(r);
		var scratch = LibC.malloc((total > 0 ? total : 1 : I64));
		Mem.setPtr(r, R_SCRATCH, scratch);
		Mem.setI64(r, R_SCRATCH_LEN, total);
		if (d != null && total > 0) LibC.memcpy(scratch, data(d), (total : I64));
		var nb = L.UV_BUF_SIZE * (n > 0 ? n : 1);
		var bufs = LibC.malloc((nb : I64));
		Mem.setPtr(r, R_BUFS, bufs);
		var off = 0;
		for (i in 0...n) {
			var len = sizes[i];
			setBuf(bufs.add(L.UV_BUF_SIZE * i), scratch.add(off), len);
			off += len;
		}
		return n;
	}

	// copies len bytes at offset src of the request's scratch into b[pos]
	public static function reqCopyOut(id:Int, b:Bytes, pos:Int, src:Int, len:Int):Void {
		var r = R(id);
		if (len > 0 && !Mem.ult(Mem.getI64(r, R_SCRATCH_LEN), (src : I64) + len))
			LibC.memcpy(data(b).add(pos), Mem.getPtr(r, R_SCRATCH).add(src), (len : I64));
	}

	// ---- socket addresses (Bytes of sizeof(struct sockaddr_storage))

	public static function sockaddrSize():Int
		return L.SOCKADDR_STORAGE_SIZE;

	public static function sockaddrIp(host:String, port:Int, v6:Bool, out:Bytes):Int {
		return Arena.scopedValue(a -> {
			var h = a.cstring(host);
			out.fill(0, L.SOCKADDR_STORAGE_SIZE, 0);
			var tmp = a.alloc(L.SOCKADDR_STORAGE_SIZE);
			var r = v6 ? U.uv_ip6_addr(h, port, tmp) : U.uv_ip4_addr(h, port, tmp);
			LibC.memcpy(data(out), tmp, (L.SOCKADDR_STORAGE_SIZE : I64));
			r;
		});
	}

	@:hxmc.noGc static function family(s:Ptr):Int
		return L.SA_FAMILY_SIZE == 1 ? Mem.getU8(s, L.SA_FAMILY) : Mem.getU16(s, L.SA_FAMILY);

	// network order
	@:hxmc.noGc static function port16(s:Ptr, off:Int):Int
		return (Mem.getU8(s, off) << 8) | Mem.getU8(s, off + 1);

	// Sockaddr.port: -1 for None
	// -1: none
	public static function sockaddrPort(sa:Bytes):Int {
		var s = data(sa);
		var f = family(s);
		if (f == L.AF_INET) return port16(s, L.SIN_PORT);
		if (f == L.AF_INET6) return port16(s, L.SIN6_PORT);
		return -1;
	}

	// Sockaddr.to_string: null for None
	public static function sockaddrToString(sa:Bytes):Null<String> {
		var buf = Mem.stack(64);
		LibC.memset(buf, 0, 64);
		var tmp = Mem.stack(128);
		LibC.memcpy(tmp, data(sa), (L.SOCKADDR_STORAGE_SIZE : I64));
		var f = family(tmp);
		if (f == L.AF_INET) U.uv_ip4_name(tmp, buf, 64) else if (f == L.AF_INET6) U.uv_ip6_name(tmp, buf, 64) else return null;
		return strOfC(buf);
	}

	// ---- TCP

	public static function tcpNoDelay(id:Int, b:Bool):Int
		return U.uv_tcp_nodelay(uvh(id), b ? 1 : 0);

	public static function tcpKeepAlive(id:Int, enable:Bool, delay:Int):Int
		return U.uv_tcp_keepalive(uvh(id), enable ? 1 : 0, delay);

	public static function tcpSimultaneousAccepts(id:Int, b:Bool):Int
		return U.uv_tcp_simultaneous_accepts(uvh(id), b ? 1 : 0);

	// (an address copied out of the heap for the call)
	static function sockaddrC(a:Arena, sa:Null<Bytes>):Ptr {
		if (sa == null) return Ptr.nil();
		var p = a.alloc(L.SOCKADDR_STORAGE_SIZE);
		LibC.memcpy(p, data(sa), (L.SOCKADDR_STORAGE_SIZE : I64));
		return p;
	}

	public static function tcpBind(id:Int, sa:Bytes, ipv6only:Bool):Int
		return Arena.scopedValue(a -> U.uv_tcp_bind(uvh(id), sockaddrC(a, sa), ipv6only ? L.UV_TCP_IPV6ONLY : 0));

	// getsockname/getpeername (tcp, udp) into out
	public static function sockName(id:Int, peer:Bool, out:Bytes):Int {
		var h = H(id);
		var u = h.add(H_UV);
		var len:Ptr<Int32> = Mem.stack(16);
		len.value = L.SOCKADDR_STORAGE_SIZE;
		var s = Mem.stack(128);
		LibC.memset(s, 0, (L.SOCKADDR_STORAGE_SIZE : I64));
		var r = if (Mem.getI32(h, H_KIND) == HK_UDP) peer ? U.uv_udp_getpeername(u, s, len) : U.uv_udp_getsockname(u, s, len) else
			peer ? U.uv_tcp_getpeername(u, s, len) : U.uv_tcp_getsockname(u, s, len);
		LibC.memcpy(data(out), s, (L.SOCKADDR_STORAGE_SIZE : I64));
		return r;
	}

	public static function tcpConnect(id:Int, sa:Bytes, req:Int):Int
		return Arena.scopedValue(a -> U.uv_tcp_connect(uvr(req), uvh(id), sockaddrC(a, sa), Callback.addr(statusCb)));

	// TCP.close_reset: the request id stands for the callback (EV_REQ with status 0)
	@:hxmc.callback static function closeResetCb(uh:Ptr):Void {
		var h = hx(uh);
		var req = Mem.getI64(h, H_RBUF).toInt();
		Mem.setPtr(h, H_RBUF, Ptr.nil());
		freeHandle(h);
		dispatch(req, EV_REQ, 0, null);
	}

	public static function tcpCloseReset(id:Int, req:Int):Int {
		var h = H(id);
		LibC.free(Mem.getPtr(h, H_RBUF));
		Mem.setI64(h, H_RBUF, req);
		Mem.setI64(h, H_RLEN, 0);
		return U.uv_tcp_close_reset(h.add(H_UV), Callback.addr(closeResetCb));
	}

	// ---- streams

	// answer to an allocation event
	public static function allocSize(n:Int):Void
		allocSizeV = n;

	@:hxmc.callback static function allocCb(uh:Ptr, suggested:I64, buf:Ptr):Void {
		allocSizeV = 0;
		dispatch(hid(uh), EV_ALLOC, suggested.toInt(), null);
		var n = allocSizeV > 0 ? allocSizeV : 0;
		var h = hx(uh);
		if (Mem.getI64(h, H_RLEN) < n || Mem.getPtr(h, H_RBUF).isNull()) {
			Mem.setPtr(h, H_RBUF, LibC.realloc(Mem.getPtr(h, H_RBUF), ((n > 0 ? n : 1) : I64)));
			Mem.setI64(h, H_RLEN, n);
		}
		setBuf(buf, Mem.getPtr(h, H_RBUF), n);
	}

	@:hxmc.noGc static function bufBase(buf:Ptr):Ptr
		return Mem.getPtr(buf, L.UV_BUF_BASE);

	@:hxmc.callback static function readCb(s:Ptr, nread:I64, buf:Ptr):Void {
		var b = nread > 0 ? bytesOf(bufBase(buf), nread.toInt()) : null;
		dispatch(hid(s), EV_READ, nread.toInt(), b);
	}

	@:hxmc.callback static function connectionCb(s:Ptr, status:Int):Void
		dispatch(hid(s), EV_CONNECTION, status, null);

	public static function streamShutdown(id:Int, req:Int):Int
		return U.uv_shutdown(uvr(req), uvh(id), Callback.addr(statusCb));

	public static function streamListen(id:Int, backlog:Int):Int
		return U.uv_listen(uvh(id), backlog, Callback.addr(connectionCb));

	public static function streamAccept(server:Int, client:Int):Int
		return U.uv_accept(uvh(server), uvh(client));

	public static function readStart(id:Int):Int
		return U.uv_read_start(uvh(id), Callback.addr(allocCb), Callback.addr(readCb));

	public static function readStop(id:Int):Int
		return U.uv_read_stop(uvh(id));

	public static function streamWrite(id:Int, req:Int, d:Bytes, sizes:Array<Int>, sendHandle:Int):Int {
		var u = uvh(id);
		var r = R(req);
		var n = reqBufs(r, d, sizes);
		var send = sendHandle > 0 ? uvh(sendHandle) : Ptr.nil();
		return U.uv_write2(r.add(R_UV), u, Mem.getPtr(r, R_BUFS), n, send, Callback.addr(statusCb));
	}

	public static function streamTryWrite(id:Int, d:Bytes, sizes:Array<Int>):Int {
		var req = reqNew();
		var r = R(req);
		var n = reqBufs(r, d, sizes);
		var res = U.uv_try_write(uvh(id), Mem.getPtr(r, R_BUFS), n);
		reqFree(req);
		return res;
	}

	public static function streamWriteQueueSize(id:Int):Int
		return U.uv_stream_get_write_queue_size(uvh(id)).toInt();

	public static function streamIsReadable(id:Int):Bool
		return U.uv_is_readable(uvh(id)) != 0;

	public static function streamIsWritable(id:Int):Bool
		return U.uv_is_writable(uvh(id)) != 0;

	public static function streamSetBlocking(id:Int, b:Bool):Int
		return U.uv_stream_set_blocking(uvh(id), b ? 1 : 0);

	// ---- pipes, ttys

	public static function pipeBind(id:Int, name:Bytes):Int
		return Arena.scopedValue(a -> U.uv_pipe_bind(uvh(id), bytesZ(a, name)));

	public static function pipeConnect(id:Int, name:Bytes, req:Int):Void
		Arena.scoped(a -> U.uv_pipe_connect(uvr(req), uvh(id), bytesZ(a, name), Callback.addr(statusCb)));

	// not in luv's Eval API: a pipe over an open descriptor (e.g. the process's stdin)
	// uv_pipe_open (not in luv's Eval API)
	public static function pipeOpen(id:Int, fd:Int):Int
		return U.uv_pipe_open(uvh(id), fd);

	// getsockname/getpeername: Bytes, null on failure (lastError)
	public static function pipeName(id:Int, peer:Bool):Null<Bytes> {
		return Arena.scopedValue(a -> {
			var buf = a.alloc(4096, 1);
			var len:Ptr<UInt64> = a.alloc(8);
			len.value = (4096 : I64);
			var r = peer ? U.uv_pipe_getpeername(uvh(id), buf, len) : U.uv_pipe_getsockname(uvh(id), buf, len);
			if (r < 0) {
				lastErr = r;
				return null;
			}
			bytesOf(buf, len.value.toInt());
		});
	}

	public static function pipePendingInstances(id:Int, n:Int):Void
		U.uv_pipe_pending_instances(uvh(id), n);

	// 0 none, 1 tcp, 2 pipe
	public static function pipePendingType(id:Int):Int {
		var u = uvh(id);
		if (U.uv_pipe_pending_count(u) <= 0) return 0;
		var t = U.uv_pipe_pending_type(u);
		return t == L.UV_TCP ? 1 : t == L.UV_NAMED_PIPE ? 2 : 0;
	}

	public static function pipeChmod(id:Int, mode:Int):Int
		return U.uv_pipe_chmod(uvh(id), mode == 0 ? L.UV_READABLE : mode == 1 ? L.UV_WRITABLE : (L.UV_READABLE | L.UV_WRITABLE));

	public static function ttySetMode(id:Int, mode:Int):Int
		return U.uv_tty_set_mode(uvh(id), mode == 0 ? L.UV_TTY_MODE_NORMAL : mode == 1 ? L.UV_TTY_MODE_RAW : L.UV_TTY_MODE_IO);

	public static function ttyResetMode():Int
		return U.uv_tty_reset_mode();

	// [width, height], null on failure
	public static function ttyGetWinSize(id:Int):Null<Array<Int>> {
		var wh:Ptr<Int32> = Mem.stack(16);
		var r = U.uv_tty_get_winsize(uvh(id), wh, wh.offset(1));
		if (r < 0) {
			lastErr = r;
			return null;
		}
		return [wh[0], wh[1]];
	}

	public static function ttySetVTermState(s:Int):Void
		U.uv_tty_set_vterm_state(s == 0 ? L.UV_TTY_SUPPORTED : L.UV_TTY_UNSUPPORTED);

	public static function ttyGetVTermState():Int {
		var s:Ptr<Int32> = Mem.stack(16);
		var r = U.uv_tty_get_vterm_state(s);
		return r < 0 ? r : (s.value == L.UV_TTY_SUPPORTED ? 0 : 1);
	}

	// ---- UDP

	public static function udpBind(id:Int, sa:Bytes, flags:Int):Int
		return Arena.scopedValue(a -> U.uv_udp_bind(uvh(id), sockaddrC(a, sa), flags));

	public static function udpConnect(id:Int, sa:Null<Bytes>):Int
		return Arena.scopedValue(a -> U.uv_udp_connect(uvh(id), sockaddrC(a, sa)));

	public static function udpSetMembership(id:Int, group:String, iface:String, source:Null<String>, join:Bool):Int {
		return Arena.scopedValue(a -> {
			var m = join ? L.UV_JOIN_GROUP : L.UV_LEAVE_GROUP;
			source != null ? U.uv_udp_set_source_membership(uvh(id), a.cstring(group), a.cstring(iface), a.cstring(source), m) : U.uv_udp_set_membership(uvh(id),
				a.cstring(group), a.cstring(iface), m);
		});
	}

	// 0 multicast loop, 1 multicast ttl, 2 broadcast, 3 ttl
	public static function udpSetOption(id:Int, opt:Int, v:Int):Int {
		var u = uvh(id);
		return switch opt {
			case 0: U.uv_udp_set_multicast_loop(u, v);
			case 1: U.uv_udp_set_multicast_ttl(u, v);
			case 2: U.uv_udp_set_broadcast(u, v);
			case _: U.uv_udp_set_ttl(u, v);
		}
	}

	public static function udpSetMulticastInterface(id:Int, iface:String):Int
		return Arena.scopedValue(a -> U.uv_udp_set_multicast_interface(uvh(id), a.cstring(iface)));

	public static function udpSend(id:Int, req:Int, d:Bytes, sizes:Array<Int>, sa:Null<Bytes>):Int {
		return Arena.scopedValue(a -> {
			var r = R(req);
			var n = reqBufs(r, d, sizes);
			U.uv_udp_send(r.add(R_UV), uvh(id), Mem.getPtr(r, R_BUFS), n, sockaddrC(a, sa), Callback.addr(statusCb));
		});
	}

	public static function udpTrySend(id:Int, d:Bytes, sizes:Array<Int>, sa:Null<Bytes>):Int {
		return Arena.scopedValue(a -> {
			var req = reqNew();
			var r = R(req);
			var n = reqBufs(r, d, sizes);
			var res = U.uv_udp_try_send(uvh(id), Mem.getPtr(r, R_BUFS), n, sockaddrC(a, sa));
			reqFree(req);
			res;
		});
	}

	// [data or null, address or null, flags]
	@:hxmc.callback static function udpRecvCb(u:Ptr, nread:I64, buf:Ptr, addr:Ptr, flags:Int):Void {
		if (nread < 0) {
			dispatch(hid(u), EV_UDP_RECV, nread.toInt(), null);
			return;
		}
		var arr:Array<Dynamic> = [null, null, null];
		arr[0] = bytesOf(bufBase(buf), nread.toInt());
		if (!addr.isNull()) arr[1] = sockaddrBytes(addr, family(addr) == L.AF_INET6 ? L.SOCKADDR_IN6_SIZE : L.SOCKADDR_IN_SIZE);
		arr[2] = flags;
		dispatch(hid(u), EV_UDP_RECV, nread.toInt(), arr);
	}

	public static function udpRecvStart(id:Int):Int
		return U.uv_udp_recv_start(uvh(id), Callback.addr(allocCb), Callback.addr(udpRecvCb));

	public static function udpRecvStop(id:Int):Int
		return U.uv_udp_recv_stop(uvh(id));

	public static function udpSendQueue(id:Int, count:Bool):Int {
		var u = uvh(id);
		return (count ? U.uv_udp_get_send_queue_count(u) : U.uv_udp_get_send_queue_size(u)).toInt();
	}

	// ---- processes

	@:hxmc.callback static function exitCb(p:Ptr, exitStatus:I64, termSignal:Int):Void {
		i64Out = exitStatus;
		dispatch(hid(p), EV_EXIT, exitStatus.toInt(), termSignal);
	}

	// redirections: per entry child fd, kind (0 ignore, 1 create pipe, 2 inherit fd,
	// 3 inherit stream), pipe flags (1 readable, 2 writable, 4 overlapped), fd or stream
	// handle id. flags: 1 setuid, 2 setgid, 4 windows_verbatim_arguments, 8 detached,
	// 16 windows_hide, 32 windows_hide_console, 64 windows_hide_gui
	public static function processSpawn(loopId:Int, cmd:Bytes, args:Array<Bytes>, env:Null<Array<Bytes>>, cwd:Null<Bytes>,
			flags:Int, uid:Int, gid:Int, redirect:Array<Int>, onExit:Bool):Int {
		var lp = loop(loopId);
		return Arena.scopedValue(a -> {
			var o = a.alloc(L.PROCESS_OPTIONS_SIZE);
			var nargs = args != null ? args.length : 0;
			var argv:Ptr<CString> = a.alloc(8 * (nargs + 1));
			for (i in 0...nargs)
				argv[i] = bytesZ(a, args[i]);
			var envp:Ptr<CString> = Ptr.nil();
			if (env != null) {
				envp = a.alloc(8 * (env.length + 1));
				for (i in 0...env.length)
					envp[i] = bytesZ(a, env[i]);
			}
			// at least 3 entries (stdin, stdout, stderr); missing ones are ignored
			var nred = redirect != null ? Std.int(redirect.length / 4) : 0;
			var count = 3;
			for (i in 0...nred) {
				var fd = redirect[4 * i];
				if (fd + 1 > count) count = fd + 1;
			}
			var stdio = a.alloc(L.STDIO_CONTAINER_SIZE * count);
			for (i in 0...count)
				Mem.setI32(stdio, L.STDIO_CONTAINER_SIZE * i + L.STDIO_FLAGS, L.UV_IGNORE);
			for (i in 0...nred) {
				var fd = redirect[4 * i], kind = redirect[4 * i + 1], pf = redirect[4 * i + 2], v = redirect[4 * i + 3];
				if (fd < 0) continue;
				// List.find: the first redirection for a descriptor wins
				var seen = false;
				for (j in 0...i)
					if (redirect[4 * j] == fd) seen = true;
				if (seen) continue;
				var e = stdio.add(L.STDIO_CONTAINER_SIZE * fd);
				switch kind {
					case 1:
						Mem.setI32(e, L.STDIO_FLAGS, L.UV_CREATE_PIPE | (pf & 1 != 0 ? L.UV_READABLE_PIPE : 0) | (pf & 2 != 0 ? L.UV_WRITABLE_PIPE : 0)
							| (pf & 4 != 0 ? L.UV_OVERLAPPED_PIPE : 0));
						Mem.setPtr(e, L.STDIO_DATA, uvh(v));
					case 2:
						Mem.setI32(e, L.STDIO_FLAGS, L.UV_INHERIT_FD);
						Mem.setI32(e, L.STDIO_DATA, v);
					case 3:
						Mem.setI32(e, L.STDIO_FLAGS, L.UV_INHERIT_STREAM);
						Mem.setPtr(e, L.STDIO_DATA, uvh(v));
					case _:
				}
			}
			Mem.setPtr(o, L.PO_FILE, bytesZ(a, cmd));
			Mem.setPtr(o, L.PO_ARGS, argv);
			Mem.setPtr(o, L.PO_ENV, envp);
			Mem.setPtr(o, L.PO_CWD, bytesZ(a, cwd));
			Mem.setI32(o, L.PO_STDIO_COUNT, count);
			Mem.setPtr(o, L.PO_STDIO, stdio);
			if (L.UID_SIZE == 1) {
				Mem.setI8(o, L.PO_UID, uid);
				Mem.setI8(o, L.PO_GID, gid);
			} else {
				Mem.setI32(o, L.PO_UID, uid);
				Mem.setI32(o, L.PO_GID, gid);
			}
			Mem.setI32(o, L.PO_FLAGS, (flags & 1 != 0 ? L.UV_PROCESS_SETUID : 0) | (flags & 2 != 0 ? L.UV_PROCESS_SETGID : 0)
				| (flags & 4 != 0 ? L.UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS : 0) | (flags & 8 != 0 ? L.UV_PROCESS_DETACHED : 0)
				| (flags & 16 != 0 ? L.UV_PROCESS_WINDOWS_HIDE : 0) | (flags & 32 != 0 ? L.UV_PROCESS_WINDOWS_HIDE_CONSOLE : 0)
				| (flags & 64 != 0 ? L.UV_PROCESS_WINDOWS_HIDE_GUI : 0));
			Mem.setPtr(o, L.PO_EXIT_CB, onExit ? Callback.addr(exitCb) : Ptr.nil());
			var h = newHandle(HK_PROCESS);
			var u = h.add(H_UV);
			var r = U.uv_spawn(lp, u, o);
			U.uv_handle_set_data(u, h);
			if (r < 0) {
				// luv: Handle.close process ignore
				U.uv_close(u, Callback.addr(closeSilentCb));
				return r;
			}
			Mem.getI32(h, H_ID);
		});
	}

	public static function disableStdioInheritance():Void
		U.uv_disable_stdio_inheritance();

	public static function killPid(pid:Int, sig:Int):Int
		return U.uv_kill(pid, sig);

	public static function processPid(id:Int):Int
		return U.uv_process_get_pid(uvh(id));

	// ---- DNS

	@:hxmc.callback static function gaiCb(req:Ptr, status:Int, res:Ptr):Void {
		Mem.setPtr(req, -R_UV + R_AI, res);
		dispatch(rid(req), EV_REQ, status, null);
	}

	@:hxmc.callback static function gniCb(req:Ptr, status:Int, host:Ptr, service:Ptr):Void
		dispatch(rid(req), EV_REQ, status, null);

	// hints: family, socktype, protocol, flags; -1: not given (no hints at all when all are)
	public static function getAddrInfo(loopId:Int, req:Int, node:Null<String>, service:Null<String>, family:Int,
			socktype:Int, protocol:Int, flags:Int, hasHints:Bool):Int {
		var lp = loop(loopId);
		return Arena.scopedValue(a -> {
			var hints = a.alloc(L.ADDRINFO_SIZE);
			Mem.setI32(hints, L.AI_FAMILY, family < 0 ? L.AF_UNSPEC : family);
			Mem.setI32(hints, L.AI_SOCKTYPE, socktype < 0 ? 0 : socktype);
			Mem.setI32(hints, L.AI_PROTOCOL, protocol < 0 ? 0 : protocol);
			Mem.setI32(hints, L.AI_FLAGS, flags < 0 ? 0 : flags);
			var r = R(req);
			reqClear(r);
			U.uv_getaddrinfo(lp, r.add(R_UV), Callback.addr(gaiCb), a.cstring(node), a.cstring(service), hasHints ? hints : Ptr.nil());
		});
	}

	// per entry: family, socktype, protocol, address (Bytes), canonical name (String or null); frees the list
	public static function addrInfoResult(req:Int):Array<Dynamic> {
		var r = R(req);
		var n = 0;
		var ai = Mem.getPtr(r, R_AI);
		while (!ai.isNull()) {
			n++;
			ai = Mem.getPtr(ai, L.AI_NEXT);
		}
		var arr:Array<Dynamic> = [for (_ in 0...5 * n) null];
		ai = Mem.getPtr(r, R_AI);
		var i = 0;
		// (the list is C memory: its pointers stay valid across allocations)
		while (!ai.isNull()) {
			arr[5 * i] = Mem.getI32(ai, L.AI_FAMILY);
			arr[5 * i + 1] = Mem.getI32(ai, L.AI_SOCKTYPE);
			arr[5 * i + 2] = Mem.getI32(ai, L.AI_PROTOCOL);
			arr[5 * i + 3] = sockaddrBytes(Mem.getPtr(ai, L.AI_ADDR), (L.AI_ADDRLEN_SIZE == 4 ? Mem.getI32(ai, L.AI_ADDRLEN) : Mem.getI64(ai, L.AI_ADDRLEN).toInt()));
			var canon = Mem.getPtr(ai, L.AI_CANONNAME);
			if (!canon.isNull()) arr[5 * i + 4] = strOfC(canon);
			ai = Mem.getPtr(ai, L.AI_NEXT);
			i++;
		}
		ai = Mem.getPtr(r, R_AI);
		if (!ai.isNull()) U.uv_freeaddrinfo(ai);
		Mem.setPtr(r, R_AI, Ptr.nil());
		return arr;
	}

	public static function getNameInfo(loopId:Int, req:Int, sa:Bytes, flags:Int):Int {
		var lp = loop(loopId);
		return Arena.scopedValue(a -> U.uv_getnameinfo(lp, uvr(req), Callback.addr(gniCb), sockaddrC(a, sa), flags));
	}

	// [host, service]
	public static function nameInfoResult(req:Int):Array<String> {
		var q = uvr(req);
		var host = strOfC(q.add(L.GNI_HOST));
		var service = strOfC(uvr(req).add(L.GNI_SERVICE));
		return [host, service];
	}

	// ---- files

	static inline var FS_OPEN = 0;
	static inline var FS_CLOSE = 1;
	static inline var FS_READ = 2;
	static inline var FS_WRITE = 3;
	static inline var FS_UNLINK = 4;
	static inline var FS_MKDIR = 5;
	static inline var FS_MKDTEMP = 6;
	static inline var FS_MKSTEMP = 7;
	static inline var FS_RMDIR = 8;
	static inline var FS_OPENDIR = 9;
	static inline var FS_CLOSEDIR = 10;
	static inline var FS_READDIR = 11;
	static inline var FS_SCANDIR = 12;
	static inline var FS_STAT = 13;
	static inline var FS_LSTAT = 14;
	static inline var FS_FSTAT = 15;
	static inline var FS_STATFS = 16;
	static inline var FS_RENAME = 17;
	static inline var FS_FSYNC = 18;
	static inline var FS_FDATASYNC = 19;
	static inline var FS_FTRUNCATE = 20;
	static inline var FS_COPYFILE = 21;
	static inline var FS_SENDFILE = 22;
	static inline var FS_ACCESS = 23;
	static inline var FS_CHMOD = 24;
	static inline var FS_FCHMOD = 25;
	static inline var FS_UTIME = 26;
	static inline var FS_LUTIME = 27;
	static inline var FS_FUTIME = 28;
	static inline var FS_LINK = 29;
	static inline var FS_SYMLINK = 30;
	static inline var FS_READLINK = 31;
	static inline var FS_REALPATH = 32;
	static inline var FS_CHOWN = 33;
	static inline var FS_LCHOWN = 34;
	static inline var FS_FCHOWN = 35;

	@:hxmc.callback static function fsCb(q:Ptr):Void
		dispatch(rid(q), EV_REQ, U.uv_fs_get_result(q).toInt(), null);

	static inline function f2l(f:Float):I64
		return haxe.Int64.fromFloat(f);

	// one entry point for luv's File functions: loop < 0 runs synchronously
	// (luv's File.Sync: the default loop, no callback). p1, p2: paths (Bytes);
	// i1..i3: ints (file, flags, mode, uid, gid, dir id, number of entries);
	// f1, f2: floats (offsets, lengths, times); data/sizes: buffers. Every
	// call is in a safe region (the synchronous ones block on the disk).
	public static function fs(op:Int, loopId:Int, req:Int, p1:Null<Bytes>, p2:Null<Bytes>, i1:Int, i2:Int, i3:Int, f1:Float, f2:Float,
			d:Null<Bytes>, sizes:Null<Array<Int>>):Int {
		var lp = loopId < 0 ? U.uv_default_loop() : loop(loopId);
		var cb = loopId < 0 ? Ptr.nil() : Callback.addr(fsCb);
		var r = R(req);
		var q = r.add(R_UV);
		return Arena.scopedValue(ar -> {
			var a = bytesZ(ar, p1), b = bytesZ(ar, p2);
			switch op {
				case FS_OPEN: UF.uv_fs_open(lp, q, a, i1, i2, cb);
				case FS_CLOSE: UF.uv_fs_close(lp, q, i1, cb);
				case FS_READ | FS_WRITE:
					var n = reqBufs(r, d, sizes);
					op == FS_READ ? UF.uv_fs_read(lp, q, i1, Mem.getPtr(r, R_BUFS), n, f2l(f1), cb) : UF.uv_fs_write(lp, q, i1, Mem.getPtr(r, R_BUFS), n, f2l(f1), cb);
				case FS_UNLINK: UF.uv_fs_unlink(lp, q, a, cb);
				case FS_MKDIR: UF.uv_fs_mkdir(lp, q, a, i1, cb);
				case FS_MKDTEMP: UF.uv_fs_mkdtemp(lp, q, a, cb);
				case FS_MKSTEMP: UF.uv_fs_mkstemp(lp, q, a, cb);
				case FS_RMDIR: UF.uv_fs_rmdir(lp, q, a, cb);
				case FS_OPENDIR: UF.uv_fs_opendir(lp, q, a, cb);
				case FS_CLOSEDIR: UF.uv_fs_closedir(lp, q, Mem.getPtr(objGet(i1), 0), cb);
				case FS_READDIR:
					var dir = Mem.getPtr(objGet(i1), 0);
					LibC.free(Mem.getPtr(r, R_DIRENTS));
					var nent = i2 > 0 ? i2 : 1;
					var dirents = LibC.malloc((L.DIRENT_SIZE * nent : I64));
					LibC.memset(dirents, 0, (L.DIRENT_SIZE * nent : I64));
					Mem.setPtr(r, R_DIRENTS, dirents);
					Mem.setPtr(dir, L.DIR_DIRENTS, dirents);
					Mem.setI64(dir, L.DIR_NENTRIES, i2 > 0 ? i2 : 0);
					Mem.setI32(r, R_DIR_ID, i1);
					UF.uv_fs_readdir(lp, q, dir, cb);
				case FS_SCANDIR: UF.uv_fs_scandir(lp, q, a, 0, cb);
				case FS_STAT: UF.uv_fs_stat(lp, q, a, cb);
				case FS_LSTAT: UF.uv_fs_lstat(lp, q, a, cb);
				case FS_FSTAT: UF.uv_fs_fstat(lp, q, i1, cb);
				case FS_STATFS: UF.uv_fs_statfs(lp, q, a, cb);
				case FS_RENAME: UF.uv_fs_rename(lp, q, a, b, cb);
				case FS_FSYNC: UF.uv_fs_fsync(lp, q, i1, cb);
				case FS_FDATASYNC: UF.uv_fs_fdatasync(lp, q, i1, cb);
				case FS_FTRUNCATE: UF.uv_fs_ftruncate(lp, q, i1, f2l(f1), cb);
				case FS_COPYFILE: UF.uv_fs_copyfile(lp, q, a, b, i1, cb);
				case FS_SENDFILE: UF.uv_fs_sendfile(lp, q, i2, i1, f2l(f1), f2l(f2), cb); // (to, from)
				case FS_ACCESS: UF.uv_fs_access(lp, q, a, i1, cb);
				case FS_CHMOD: UF.uv_fs_chmod(lp, q, a, i1, cb);
				case FS_FCHMOD: UF.uv_fs_fchmod(lp, q, i1, i2, cb);
				case FS_UTIME: UF.uv_fs_utime(lp, q, a, f1, f2, cb);
				case FS_LUTIME: UF.uv_fs_lutime(lp, q, a, f1, f2, cb);
				case FS_FUTIME: UF.uv_fs_futime(lp, q, i1, f1, f2, cb);
				case FS_LINK: UF.uv_fs_link(lp, q, a, b, cb);
				case FS_SYMLINK: UF.uv_fs_symlink(lp, q, a, b, i1, cb);
				case FS_READLINK: UF.uv_fs_readlink(lp, q, a, cb);
				case FS_REALPATH: UF.uv_fs_realpath(lp, q, a, cb);
				case FS_CHOWN: UF.uv_fs_chown(lp, q, a, i1, i2, cb);
				case FS_LCHOWN: UF.uv_fs_lchown(lp, q, a, i1, i2, cb);
				case FS_FCHOWN: UF.uv_fs_fchown(lp, q, i1, i2, i3, cb);
				case _: L.UV_EINVAL;
			}
		});
	}

	public static function fsResult(req:Int):Int
		return U.uv_fs_get_result(uvr(req)).toInt();

	public static function fsCleanup(req:Int):Void
		U.uv_fs_req_cleanup(uvr(req));

	public static function fsPath(req:Int):Null<Bytes>
		return bytesOfC(U.uv_fs_get_path(uvr(req)));

	public static function fsPtrString(req:Int):Null<Bytes>
		return bytesOfC(U.uv_fs_get_ptr(uvr(req)));

	// 20 int64: dev mode nlink uid gid rdev ino size blksize blocks flags gen, then sec/nsec of atim mtim ctim birthtim
	@:hxmc.noGc static function statInto(p:Ptr, s:Ptr) {
		for (i in 0...12)
			Mem.setI64(p, 8 * i, Mem.getI64(s, 8 * i));
		for (i in 0...4) {
			var t = L.STAT_ATIM + i * 2 * L.LONG_SIZE;
			Mem.setI64(p, 8 * (12 + 2 * i), getLong(s, t));
			Mem.setI64(p, 8 * (13 + 2 * i), getLong(s, t + L.LONG_SIZE));
		}
	}

	// 160 bytes
	public static function fsStat(req:Int, out:Bytes):Void {
		var s = U.uv_fs_get_statbuf(uvr(req));
		var tmp = Mem.stack(160);
		statInto(tmp, s);
		LibC.memcpy(data(out), tmp, 160);
	}

	// 11 int64: type bsize blocks bfree bavail files ffree f_spare[4]
	// 88 bytes
	public static function fsStatfs(req:Int, out:Bytes):Void {
		var s = U.uv_fs_get_ptr(uvr(req));
		LibC.memcpy(data(out), s, 88);
	}

	public static function fsDir(req:Int):Int {
		var d = LibC.malloc(8);
		Mem.setPtr(d, 0, U.uv_fs_get_ptr(uvr(req)));
		return objAdd(d);
	}

	// readdir: per entry, type then name (Bytes)
	public static function fsDirents(req:Int):Array<Dynamic> {
		var r = R(req);
		var n = U.uv_fs_get_result(r.add(R_UV)).toInt();
		if (n < 0) n = 0;
		var arr:Array<Dynamic> = [for (_ in 0...2 * n) null];
		var ents = Mem.getPtr(r, R_DIRENTS);
		for (i in 0...n) {
			var e = ents.add(L.DIRENT_SIZE * i);
			arr[2 * i] = constant(10, Mem.getI32(e, L.DIRENT_TYPE));
			arr[2 * i + 1] = bytesOfC(Mem.getPtr(e, L.DIRENT_NAME));
		}
		return arr;
	}

	// scandir_next: [type, name] or null at the end
	public static function fsScandirNext(req:Int):Null<Array<Dynamic>> {
		var ent = Mem.stack(16);
		if (U.uv_fs_scandir_next(uvr(req), ent) < 0) return null;
		var t = constant(10, Mem.getI32(ent, L.DIRENT_TYPE));
		var name = bytesOfC(Mem.getPtr(ent, L.DIRENT_NAME));
		return [t, name];
	}

	// ---- fs events and polls

	@:hxmc.callback static function fsEventCb(e:Ptr, filename:Ptr, events:Int, status:Int):Void {
		var arr:Array<Dynamic> = [null, null];
		if (!filename.isNull()) arr[0] = bytesOfC(filename);
		arr[1] = events;
		dispatch(hid(e), EV_FS_EVENT, status, arr);
	}

	public static function fsEventStart(id:Int, path:Bytes, flags:Int):Int
		return Arena.scopedValue(a -> U.uv_fs_event_start(uvh(id), Callback.addr(fsEventCb), bytesZ(a, path), flags));

	public static function fsEventStop(id:Int):Int
		return U.uv_fs_event_stop(uvh(id));

	static function statBytes(s:Ptr):Bytes {
		var b = Bytes.alloc(160);
		var tmp = Mem.stack(160);
		statInto(tmp, s);
		LibC.memcpy(data(b), tmp, 160);
		return b;
	}

	@:hxmc.callback static function fsPollCb(p:Ptr, status:Int, prev:Ptr, curr:Ptr):Void {
		if (status < 0) {
			dispatch(hid(p), EV_FS_POLL, status, null);
			return;
		}
		var arr:Array<Dynamic> = [statBytes(prev), statBytes(curr)];
		dispatch(hid(p), EV_FS_POLL, status, arr);
	}

	public static function fsPollStart(id:Int, path:Bytes, interval:Int):Int
		return Arena.scopedValue(a -> U.uv_fs_poll_start(uvh(id), Callback.addr(fsPollCb), bytesZ(a, path), interval));

	public static function fsPollStop(id:Int):Int
		return U.uv_fs_poll_stop(uvh(id));

	// ---- random

	// loop -1 runs synchronously; the bytes are copied out with reqCopyOut
	public static function random(loopId:Int, req:Int, len:Int):Int {
		var r = R(req);
		reqClear(r);
		var n = len > 0 ? len : 0;
		var scratch = LibC.malloc((len > 0 ? len : 1 : I64));
		Mem.setPtr(r, R_SCRATCH, scratch);
		Mem.setI64(r, R_SCRATCH_LEN, n);
		if (loopId < 0) return UF.uv_random(Ptr.nil(), Ptr.nil(), scratch, (n : I64), 0, Ptr.nil());
		return UF.uv_random(loop(loopId), r.add(R_UV), scratch, (n : I64), 0, Callback.addr(randomCb));
	}

	// ---- environment, time, paths, system

	public static function getEnv(name:String):Null<Bytes> {
		return Arena.scopedValue(a -> {
			var n = a.cstring(name);
			var len:Ptr<UInt64> = a.alloc(8);
			len.value = (256 : I64);
			var buf = a.alloc(256, 1);
			var r = U.uv_os_getenv(n, buf, len);
			if (r == L.UV_ENOBUFS) {
				buf = a.alloc(len.value.toInt(), 1);
				r = U.uv_os_getenv(n, buf, len);
			}
			if (r < 0) {
				lastErr = r;
				return null;
			}
			bytesOf(buf, len.value.toInt());
		});
	}

	// null: unset
	public static function setEnv(name:String, value:Null<Bytes>):Int
		return Arena.scopedValue(a -> value != null ? U.uv_os_setenv(a.cstring(name), bytesZ(a, value)) : U.uv_os_unsetenv(a.cstring(name)));

	// name (String), value (Bytes), ...; null on failure
	public static function environ():Null<Array<Dynamic>> {
		var items:Ptr<Ptr> = Mem.stack(16);
		var count:Ptr<Int32> = items.raw().add(8);
		var r = U.uv_os_environ(items, count);
		if (r < 0) {
			lastErr = r;
			return null;
		}
		var n = count.value;
		var it = items.value;
		var arr:Array<Dynamic> = [for (_ in 0...2 * n) null];
		for (i in 0...n) {
			arr[2 * i] = strOfC(Mem.getPtr(it, 16 * i));
			arr[2 * i + 1] = bytesOfC(Mem.getPtr(it, 16 * i + 8));
		}
		U.uv_os_free_environ(it, n);
		return arr;
	}

	// sec into i64Out, usec returned; negative error
	// usec; sec in i64
	public static function getTimeOfDay():Int {
		var tv = Mem.stack(16);
		var r = U.uv_gettimeofday(tv);
		if (r < 0) return r;
		i64Out = Mem.getI64(tv, 0);
		return Mem.getI32(tv, 8);
	}

	// i64
	public static function hrTime():Void
		i64Out = U.uv_hrtime();

	public static function sleep(ms:Int):Void
		UF.uv_sleep(ms);

	// 0 exepath, 1 cwd, 2 homedir, 3 tmpdir: Bytes, null on failure
	public static function path(which:Int):Null<Bytes> {
		return Arena.scopedValue(a -> {
			var buf = a.alloc(4096, 1);
			var len:Ptr<UInt64> = a.alloc(8);
			len.value = (4096 : I64);
			var r = which == 0 ? U.uv_exepath(buf, len) : which == 1 ? U.uv_cwd(buf, len) : which == 2 ? U.uv_os_homedir(buf, len) : U.uv_os_tmpdir(buf, len);
			if (r < 0) {
				lastErr = r;
				return null;
			}
			bytesOf(buf, len.value.toInt());
		});
	}

	public static function chdir(dir:Bytes):Int
		return Arena.scopedValue(a -> U.uv_chdir(bytesZ(a, dir)));

	// name, is_internal, physical (Bytes), address, netmask per interface; null on failure
	public static function interfaceAddresses():Null<Array<Dynamic>> {
		var out:Ptr<Ptr> = Mem.stack(16);
		var count:Ptr<Int32> = out.raw().add(8);
		var r = U.uv_interface_addresses(out, count);
		if (r < 0) {
			lastErr = r;
			return null;
		}
		var n = count.value;
		var ifs = out.value;
		var arr:Array<Dynamic> = [for (_ in 0...5 * n) null];
		for (i in 0...n) {
			var e = ifs.add(L.IFADDR_SIZE * i);
			arr[5 * i] = strOfC(Mem.getPtr(e, L.IFADDR_NAME));
			arr[5 * i + 1] = Mem.getI32(e, L.IFADDR_INTERNAL) != 0;
			arr[5 * i + 2] = bytesOf(e.add(L.IFADDR_PHYS), 6);
			arr[5 * i + 3] = sockaddrBytes(e.add(L.IFADDR_ADDRESS), L.SOCKADDR_IN6_SIZE);
			arr[5 * i + 4] = sockaddrBytes(e.add(L.IFADDR_NETMASK), L.SOCKADDR_IN6_SIZE);
		}
		U.uv_free_interface_addresses(ifs, n);
		return arr;
	}

	// 0 if_indextoname, 1 if_indextoiid, 2 gethostname: String, null on failure
	public static function netName(which:Int, index:Int):Null<String> {
		return Arena.scopedValue(a -> {
			var buf = a.alloc(1024, 1);
			var len:Ptr<UInt64> = a.alloc(8);
			len.value = (1024 : I64);
			var r = which == 0 ? U.uv_if_indextoname(index, buf, len) : which == 1 ? U.uv_if_indextoiid(index, buf, len) : U.uv_os_gethostname(buf, len);
			if (r < 0) {
				lastErr = r;
				return null;
			}
			Str.ofUtf8(buf, len.value.toInt());
		});
	}

	// lastError
	public static function uptime():Float {
		var t:Ptr<Float> = Mem.stack(16);
		t.value = 0;
		lastErr = U.uv_uptime(t);
		return t.value;
	}

	public static function loadAvg():Array<Float> {
		var avg:Ptr<Float> = Mem.stack(32);
		U.uv_loadavg(avg);
		return [avg[0], avg[1], avg[2]];
	}

	// 0 free, 1 total, 2 constrained, 3 resident set (lastError): into i64Out
	// i64 (resident set: lastError)
	public static function memory(which:Int):Void {
		if (which == 3) {
			var rss:Ptr<UInt64> = Mem.stack(16);
			rss.value = (0 : I64);
			lastErr = U.uv_resident_set_memory(rss);
			i64Out = rss.value;
			return;
		}
		i64Out = which == 0 ? U.uv_get_free_memory() : which == 1 ? U.uv_get_total_memory() : U.uv_get_constrained_memory();
	}

	// lastError
	public static function getPriority(pid:Int):Int {
		var p:Ptr<Int32> = Mem.stack(16);
		p.value = 0;
		lastErr = U.uv_os_getpriority(pid, p);
		return p.value;
	}

	public static function setPriority(pid:Int, p:Int):Int
		return U.uv_os_setpriority(pid, p);

	// 18 int64: utime sec usec, stime sec usec, maxrss ixrss idrss isrss minflt majflt nswap inblock oublock msgsnd msgrcv nsignals nvcsw nivcsw
	// 144 bytes
	public static function getRUsage(out:Bytes):Int {
		var u = Mem.stack(256);
		var r = U.uv_getrusage(u);
		if (r < 0) return r;
		var v = Mem.stack(144);
		Mem.setI64(v, 0, getLong(u, L.RUSAGE_UTIME));
		Mem.setI64(v, 8, getLong(u, L.RUSAGE_UTIME + L.LONG_SIZE));
		Mem.setI64(v, 16, getLong(u, L.RUSAGE_STIME));
		Mem.setI64(v, 24, getLong(u, L.RUSAGE_STIME + L.LONG_SIZE));
		for (i in 0...14)
			Mem.setI64(v, 32 + 8 * i, Mem.getI64(u, L.RUSAGE_MAXRSS + 8 * i));
		LibC.memcpy(data(out), v, 144);
		return 0;
	}

	// per cpu: model (String), speed, then times user nice sys idle irq in a Bytes (5 int64); null on failure
	public static function cpuInfo():Null<Array<Dynamic>> {
		var out:Ptr<Ptr> = Mem.stack(16);
		var count:Ptr<Int32> = out.raw().add(8);
		var r = U.uv_cpu_info(out, count);
		if (r < 0) {
			lastErr = r;
			return null;
		}
		var n = count.value;
		var c = out.value;
		var arr:Array<Dynamic> = [for (_ in 0...3 * n) null];
		for (i in 0...n) {
			var e = c.add(L.CPU_INFO_SIZE * i);
			arr[3 * i] = strOfC(Mem.getPtr(e, L.CPU_MODEL));
			arr[3 * i + 1] = Mem.getI32(e, L.CPU_SPEED);
			arr[3 * i + 2] = bytesOf(e.add(L.CPU_TIMES), 40);
		}
		U.uv_free_cpu_info(c, n);
		return arr;
	}

	// [sysname, release, version, machine]; null on failure
	public static function uname():Null<Array<String>> {
		return Arena.scopedValue(a -> {
			var u = a.alloc(4 * 256, 1);
			var r = U.uv_os_uname(u);
			if (r < 0) {
				lastErr = r;
				return null;
			}
			[for (i in 0...4) strOfC(u.add(256 * i))];
		});
	}

	public static function getPid():Int
		return U.uv_os_getpid();

	public static function getPPid():Int
		return U.uv_os_getppid();

	// [username, uid, gid, shell or null, homedir (Bytes)]; null on failure
	public static function getPasswd():Null<Array<Dynamic>> {
		return Arena.scopedValue(a -> {
			var p = a.alloc(L.PASSWD_SIZE);
			var r = U.uv_os_get_passwd(p);
			if (r < 0) {
				lastErr = r;
				return null;
			}
			var arr:Array<Dynamic> = [null, null, null, null, null];
			arr[0] = strOfC(Mem.getPtr(p, L.PASSWD_USERNAME));
			arr[1] = getLong(p, L.PASSWD_UID).toInt();
			arr[2] = getLong(p, L.PASSWD_GID).toInt();
			var shell = Mem.getPtr(p, L.PASSWD_SHELL);
			if (!shell.isNull()) arr[3] = strOfC(shell);
			arr[4] = bytesOfC(Mem.getPtr(p, L.PASSWD_HOMEDIR));
			U.uv_os_free_passwd(p);
			arr;
		});
	}

	// not in luv's Eval API: what a descriptor is (0 unknown, 1 tty, 2 pipe, 3 tcp, 4 udp, 5 file)
	public static function guessHandle(fd:Int):Int {
		var t = U.uv_guess_handle(fd);
		return t == L.UV_TTY ? 1 : t == L.UV_NAMED_PIPE ? 2 : t == L.UV_TCP ? 3 : t == L.UV_UDP ? 4 : t == L.UV_FILE ? 5 : 0;
	}
}

// libuv (uv.o): calls that never block nor call back (their callbacks run
// later, inside uv_run)
@:hxmc.c @:hxmc.fast private extern class U {
	static function uv_strerror_r(err:Int, buf:Ptr, len:I64):Ptr;
	static function uv_err_name_r(err:Int, buf:Ptr, len:I64):Ptr;
	static function uv_translate_sys_error(e:Int):Int;
	static function uv_version_string():Ptr;
	static function uv_default_loop():Ptr;
	static function uv_loop_size():I64;
	static function uv_loop_init(l:Ptr):Int;
	static function uv_stop(l:Ptr):Void;
	static function uv_loop_close(l:Ptr):Int;
	static function uv_loop_alive(l:Ptr):Int;
	static function uv_now(l:Ptr):I64;
	static function uv_update_time(l:Ptr):Void;
	static function uv_library_shutdown():Void;
	static function uv_metrics_idle_time(l:Ptr):I64;
	static function uv_handle_size(t:Int):I64;
	static function uv_req_size(t:Int):I64;
	static function uv_handle_set_data(h:Ptr, d:Ptr):Void;
	static function uv_req_set_data(r:Ptr, d:Ptr):Void;
	static function uv_idle_init(l:Ptr, h:Ptr):Int;
	static function uv_prepare_init(l:Ptr, h:Ptr):Int;
	static function uv_check_init(l:Ptr, h:Ptr):Int;
	static function uv_timer_init(l:Ptr, h:Ptr):Int;
	static function uv_async_init(l:Ptr, h:Ptr, cb:Ptr):Int;
	static function uv_tcp_init(l:Ptr, h:Ptr):Int;
	static function uv_tcp_init_ex(l:Ptr, h:Ptr, flags:Int):Int;
	static function uv_udp_init_ex(l:Ptr, h:Ptr, flags:Int):Int;
	static function uv_pipe_init(l:Ptr, h:Ptr, ipc:Int):Int;
	static function uv_tty_init(l:Ptr, h:Ptr, fd:Int, unused:Int):Int;
	static function uv_signal_init(l:Ptr, h:Ptr):Int;
	static function uv_fs_event_init(l:Ptr, h:Ptr):Int;
	static function uv_fs_poll_init(l:Ptr, h:Ptr):Int;
	static function uv_is_closing(h:Ptr):Int;
	static function uv_close(h:Ptr, cb:Ptr):Void;
	static function uv_is_active(h:Ptr):Int;
	static function uv_ref(h:Ptr):Void;
	static function uv_unref(h:Ptr):Void;
	static function uv_has_ref(h:Ptr):Int;
	static function uv_send_buffer_size(h:Ptr, v:Ptr<Int32>):Int;
	static function uv_recv_buffer_size(h:Ptr, v:Ptr<Int32>):Int;
	static function uv_idle_start(h:Ptr, cb:Ptr):Int;
	static function uv_prepare_start(h:Ptr, cb:Ptr):Int;
	static function uv_check_start(h:Ptr, cb:Ptr):Int;
	static function uv_idle_stop(h:Ptr):Int;
	static function uv_prepare_stop(h:Ptr):Int;
	static function uv_check_stop(h:Ptr):Int;
	static function uv_timer_start(h:Ptr, cb:Ptr, timeout:I64, repeat:I64):Int;
	static function uv_timer_stop(h:Ptr):Int;
	static function uv_timer_again(h:Ptr):Int;
	static function uv_timer_set_repeat(h:Ptr, repeat:I64):Void;
	static function uv_timer_get_repeat(h:Ptr):I64;
	static function uv_timer_get_due_in(h:Ptr):I64;
	static function uv_async_send(h:Ptr):Int;
	static function uv_signal_start(h:Ptr, cb:Ptr, signum:Int):Int;
	static function uv_signal_start_oneshot(h:Ptr, cb:Ptr, signum:Int):Int;
	static function uv_signal_stop(h:Ptr):Int;
	static function uv_freeaddrinfo(ai:Ptr):Void;
	static function uv_cancel(r:Ptr):Int;
	static function uv_ip4_addr(ip:CString, port:Int, out:Ptr):Int;
	static function uv_ip6_addr(ip:CString, port:Int, out:Ptr):Int;
	static function uv_ip4_name(src:Ptr, dst:Ptr, size:I64):Int;
	static function uv_ip6_name(src:Ptr, dst:Ptr, size:I64):Int;
	static function uv_tcp_nodelay(h:Ptr, enable:Int):Int;
	static function uv_tcp_keepalive(h:Ptr, enable:Int, delay:Int):Int;
	static function uv_tcp_simultaneous_accepts(h:Ptr, enable:Int):Int;
	static function uv_tcp_bind(h:Ptr, addr:Ptr, flags:Int):Int;
	static function uv_udp_getpeername(h:Ptr, addr:Ptr, len:Ptr<Int32>):Int;
	static function uv_udp_getsockname(h:Ptr, addr:Ptr, len:Ptr<Int32>):Int;
	static function uv_tcp_getpeername(h:Ptr, addr:Ptr, len:Ptr<Int32>):Int;
	static function uv_tcp_getsockname(h:Ptr, addr:Ptr, len:Ptr<Int32>):Int;
	static function uv_tcp_connect(req:Ptr, h:Ptr, addr:Ptr, cb:Ptr):Int;
	static function uv_tcp_close_reset(h:Ptr, cb:Ptr):Int;
	static function uv_shutdown(req:Ptr, h:Ptr, cb:Ptr):Int;
	static function uv_listen(h:Ptr, backlog:Int, cb:Ptr):Int;
	static function uv_accept(server:Ptr, client:Ptr):Int;
	static function uv_read_start(h:Ptr, alloc:Ptr, read:Ptr):Int;
	static function uv_read_stop(h:Ptr):Int;
	static function uv_write2(req:Ptr, h:Ptr, bufs:Ptr, n:Int, send:Ptr, cb:Ptr):Int;
	static function uv_try_write(h:Ptr, bufs:Ptr, n:Int):Int;
	static function uv_stream_get_write_queue_size(h:Ptr):I64;
	static function uv_is_readable(h:Ptr):Int;
	static function uv_is_writable(h:Ptr):Int;
	static function uv_stream_set_blocking(h:Ptr, b:Int):Int;
	static function uv_pipe_bind(h:Ptr, name:CString):Int;
	static function uv_pipe_connect(req:Ptr, h:Ptr, name:CString, cb:Ptr):Void;
	static function uv_pipe_open(h:Ptr, fd:Int):Int;
	static function uv_pipe_getpeername(h:Ptr, buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_pipe_getsockname(h:Ptr, buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_pipe_pending_instances(h:Ptr, n:Int):Void;
	static function uv_pipe_pending_count(h:Ptr):Int;
	static function uv_pipe_pending_type(h:Ptr):Int;
	static function uv_pipe_chmod(h:Ptr, flags:Int):Int;
	static function uv_tty_set_mode(h:Ptr, mode:Int):Int;
	static function uv_tty_reset_mode():Int;
	static function uv_tty_get_winsize(h:Ptr, w:Ptr<Int32>, hh:Ptr<Int32>):Int;
	static function uv_tty_set_vterm_state(s:Int):Void;
	static function uv_tty_get_vterm_state(s:Ptr<Int32>):Int;
	static function uv_udp_bind(h:Ptr, addr:Ptr, flags:Int):Int;
	static function uv_udp_connect(h:Ptr, addr:Ptr):Int;
	static function uv_udp_set_source_membership(h:Ptr, group:CString, iface:CString, source:CString, m:Int):Int;
	static function uv_udp_set_membership(h:Ptr, group:CString, iface:CString, m:Int):Int;
	static function uv_udp_set_multicast_loop(h:Ptr, on:Int):Int;
	static function uv_udp_set_multicast_ttl(h:Ptr, ttl:Int):Int;
	static function uv_udp_set_broadcast(h:Ptr, on:Int):Int;
	static function uv_udp_set_ttl(h:Ptr, ttl:Int):Int;
	static function uv_udp_set_multicast_interface(h:Ptr, iface:CString):Int;
	static function uv_udp_send(req:Ptr, h:Ptr, bufs:Ptr, n:Int, addr:Ptr, cb:Ptr):Int;
	static function uv_udp_try_send(h:Ptr, bufs:Ptr, n:Int, addr:Ptr):Int;
	static function uv_udp_recv_start(h:Ptr, alloc:Ptr, recv:Ptr):Int;
	static function uv_udp_recv_stop(h:Ptr):Int;
	static function uv_udp_get_send_queue_count(h:Ptr):I64;
	static function uv_udp_get_send_queue_size(h:Ptr):I64;
	static function uv_spawn(l:Ptr, h:Ptr, options:Ptr):Int;
	static function uv_disable_stdio_inheritance():Void;
	static function uv_kill(pid:Int, sig:Int):Int;
	static function uv_process_get_pid(h:Ptr):Int;
	static function uv_getaddrinfo(l:Ptr, req:Ptr, cb:Ptr, node:CString, service:CString, hints:Ptr):Int;
	static function uv_getnameinfo(l:Ptr, req:Ptr, cb:Ptr, addr:Ptr, flags:Int):Int;
	static function uv_fs_event_start(h:Ptr, cb:Ptr, path:CString, flags:Int):Int;
	static function uv_fs_event_stop(h:Ptr):Int;
	static function uv_fs_poll_start(h:Ptr, cb:Ptr, path:CString, interval:Int):Int;
	static function uv_fs_poll_stop(h:Ptr):Int;
	static function uv_os_getenv(name:CString, buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_os_setenv(name:CString, value:CString):Int;
	static function uv_os_unsetenv(name:CString):Int;
	static function uv_os_environ(items:Ptr<Ptr>, count:Ptr<Int32>):Int;
	static function uv_os_free_environ(items:Ptr, count:Int):Void;
	static function uv_gettimeofday(tv:Ptr):Int;
	static function uv_hrtime():I64;
	static function uv_exepath(buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_cwd(buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_os_homedir(buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_os_tmpdir(buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_chdir(dir:CString):Int;
	static function uv_interface_addresses(out:Ptr<Ptr>, count:Ptr<Int32>):Int;
	static function uv_free_interface_addresses(a:Ptr, count:Int):Void;
	static function uv_if_indextoname(index:Int, buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_if_indextoiid(index:Int, buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_os_gethostname(buf:Ptr, len:Ptr<UInt64>):Int;
	static function uv_uptime(t:Ptr<Float>):Int;
	static function uv_loadavg(avg:Ptr<Float>):Void;
	static function uv_resident_set_memory(rss:Ptr<UInt64>):Int;
	static function uv_get_free_memory():I64;
	static function uv_get_total_memory():I64;
	static function uv_get_constrained_memory():I64;
	static function uv_os_getpriority(pid:Int, p:Ptr<Int32>):Int;
	static function uv_os_setpriority(pid:Int, p:Int):Int;
	static function uv_getrusage(u:Ptr):Int;
	static function uv_cpu_info(out:Ptr<Ptr>, count:Ptr<Int32>):Int;
	static function uv_free_cpu_info(c:Ptr, count:Int):Void;
	static function uv_os_uname(u:Ptr):Int;
	static function uv_os_getpid():Int;
	static function uv_os_getppid():Int;
	static function uv_os_get_passwd(p:Ptr):Int;
	static function uv_os_free_passwd(p:Ptr):Void;
	static function uv_guess_handle(fd:Int):Int;
	static function uv_fs_get_result(req:Ptr):I64;
	static function uv_fs_get_ptr(req:Ptr):Ptr;
	static function uv_fs_get_path(req:Ptr):Ptr;
	static function uv_fs_get_statbuf(req:Ptr):Ptr;
	static function uv_fs_req_cleanup(req:Ptr):Void;
	static function uv_fs_scandir_next(req:Ptr, ent:Ptr):Int;
}

// libuv calls in a safe region: the loop (it waits, and its callbacks run
// Haxe code), the file system (synchronous calls block on the disk; the
// asynchronous ones share the functions), sleeping, random bytes
@:hxmc.c private extern class UB {
	static function uv_run(l:Ptr, mode:Int):Int;
}

@:hxmc.c private extern class UF {
	static function uv_fs_open(l:Ptr, req:Ptr, path:CString, flags:Int, mode:Int, cb:Ptr):Int;
	static function uv_fs_close(l:Ptr, req:Ptr, file:Int, cb:Ptr):Int;
	static function uv_fs_read(l:Ptr, req:Ptr, file:Int, bufs:Ptr, n:Int, offset:I64, cb:Ptr):Int;
	static function uv_fs_write(l:Ptr, req:Ptr, file:Int, bufs:Ptr, n:Int, offset:I64, cb:Ptr):Int;
	static function uv_fs_unlink(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_mkdir(l:Ptr, req:Ptr, path:CString, mode:Int, cb:Ptr):Int;
	static function uv_fs_mkdtemp(l:Ptr, req:Ptr, tpl:CString, cb:Ptr):Int;
	static function uv_fs_mkstemp(l:Ptr, req:Ptr, tpl:CString, cb:Ptr):Int;
	static function uv_fs_rmdir(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_opendir(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_closedir(l:Ptr, req:Ptr, dir:Ptr, cb:Ptr):Int;
	static function uv_fs_readdir(l:Ptr, req:Ptr, dir:Ptr, cb:Ptr):Int;
	static function uv_fs_scandir(l:Ptr, req:Ptr, path:CString, flags:Int, cb:Ptr):Int;
	static function uv_fs_stat(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_lstat(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_fstat(l:Ptr, req:Ptr, file:Int, cb:Ptr):Int;
	static function uv_fs_statfs(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_rename(l:Ptr, req:Ptr, path:CString, newPath:CString, cb:Ptr):Int;
	static function uv_fs_fsync(l:Ptr, req:Ptr, file:Int, cb:Ptr):Int;
	static function uv_fs_fdatasync(l:Ptr, req:Ptr, file:Int, cb:Ptr):Int;
	static function uv_fs_ftruncate(l:Ptr, req:Ptr, file:Int, offset:I64, cb:Ptr):Int;
	static function uv_fs_copyfile(l:Ptr, req:Ptr, path:CString, newPath:CString, flags:Int, cb:Ptr):Int;
	static function uv_fs_sendfile(l:Ptr, req:Ptr, out:Int, inFd:Int, offset:I64, length:I64, cb:Ptr):Int;
	static function uv_fs_access(l:Ptr, req:Ptr, path:CString, mode:Int, cb:Ptr):Int;
	static function uv_fs_chmod(l:Ptr, req:Ptr, path:CString, mode:Int, cb:Ptr):Int;
	static function uv_fs_fchmod(l:Ptr, req:Ptr, file:Int, mode:Int, cb:Ptr):Int;
	static function uv_fs_utime(l:Ptr, req:Ptr, path:CString, atime:Float, mtime:Float, cb:Ptr):Int;
	static function uv_fs_lutime(l:Ptr, req:Ptr, path:CString, atime:Float, mtime:Float, cb:Ptr):Int;
	static function uv_fs_futime(l:Ptr, req:Ptr, file:Int, atime:Float, mtime:Float, cb:Ptr):Int;
	static function uv_fs_link(l:Ptr, req:Ptr, path:CString, newPath:CString, cb:Ptr):Int;
	static function uv_fs_symlink(l:Ptr, req:Ptr, path:CString, newPath:CString, flags:Int, cb:Ptr):Int;
	static function uv_fs_readlink(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_realpath(l:Ptr, req:Ptr, path:CString, cb:Ptr):Int;
	static function uv_fs_chown(l:Ptr, req:Ptr, path:CString, uid:Int, gid:Int, cb:Ptr):Int;
	static function uv_fs_lchown(l:Ptr, req:Ptr, path:CString, uid:Int, gid:Int, cb:Ptr):Int;
	static function uv_fs_fchown(l:Ptr, req:Ptr, file:Int, uid:Int, gid:Int, cb:Ptr):Int;
	static function uv_random(l:Ptr, req:Ptr, buf:Ptr, len:I64, flags:Int, cb:Ptr):Int;
	static function uv_sleep(ms:Int):Void;
}
