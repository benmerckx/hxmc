package macros.eval;

import core.Globals;
import core.ds.Failure;
import core.ds.InvalidArgument;
import haxe.Int64;
import haxe.io.Bytes;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalString;
import macros.eval.EvalEncode;
import macros.eval.EvalDecode;
import macros.eval.EvalExceptions;
import macros.eval.EvalMisc;
import macros.eval.EvalField;
import macros.eval.EvalIntegers;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeUv as Uv;
#end

using macros.eval.EvalValue.EvalValueTools;

// port: upstream calls the OCaml luv library (libuv bindings). On the hxmc host
// (hxmc/) libuv is reached through `hxmc.NativeUv` (hxmc/std/hxmc/rt/Uv.hx),
// and this module also carries the parts of luv that are OCaml code
// (callback bookkeeping, result conversion, `Buffer`, the request life cycle
// of `File`), following luv's sources. On other hosts, and in hxmc builds
// without libuv (-DHXMC_NO_UV, WebAssembly), every eval.luv native fails with "libuv
// (eval.luv) is not supported by haxe-in-haxe", except `Thread`, `Once`,
// `Mutex`, `RwLock`, `Semaphore`, `Condition` and `Barrier`, which need no
// libuv here (see below).
//
// Representation (see `Vhandle`): loops, handles, requests and directories
// are integer ids of the host; threads, thread pool requests and
// synchronization objects are the classes at the end of this module; files
// are descriptors;
// `Luv.Buffer.t` (a Bigarray) is `LuvBuffer`, a view on a Bytes, so `sub`
// shares memory as upstream; socket addresses are Bytes holding a
// `sockaddr_storage`; a process redirection is a `LuvRedirection`.
//
// libuv runs callbacks inside `uv_run` only: `Loop.run` passes `dispatch` to
// the host, which reports each event by handle or request id. As luv's
// trampolines do, exceptions escaping a callback go to the unhandled
// exception handler (`Luv.Error.set_on_unhandled_exception`, installed by
// `EvalMain.create`).
//
// Deviations:
// - Threads (luv: libuv's OS threads, its thread pool and its
//   synchronization primitives) are host threads (`sys.thread`), with the
//   primitives written over host locks (`LuvThreadHandle`, `LuvThreadPool`,
//   `LuvSync` below); they run Eval code holding `EvalLock`.
//   `ThreadPool.queueWork` runs the work on a pool
//   thread (UV_THREADPOOL_SIZE of them, default 4), which signals an async
//   handle of the loop, whose callback calls the after-work callback, as
//   libuv does; `Request.cancel` cancels work no pool thread took yet.
//   `Thread.create` ignores the stack size. Error results of the primitives
//   are luv error indices directly.
// - Memory of handles is released when their close completes; requests
//   made by the natives are released when they complete; nothing else is
//   finalized (upstream relies on the OCaml GC).
// - Reads go through host memory: the data of a read is copied into the
//   buffer `allocate` returned (luv reads into it directly).
// - `Bigarray` bounds errors are `InvalidArgument`; `Buffer.blitToBytes` and
//   `blitFromBytes` fail on out-of-range copies (upstream's memcpy does not
//   check).
class EvalLuv {
	// port: ---- host access
	static function notSupported():Dynamic {
		return EvalContext.excString("libuv (eval.luv) is not supported by haxe-in-haxe");
	}

	// port: whether eval.luv works on this host.
	public static function available():Bool {
		#if (target.name == "hxmc")
		return Uv.available();
		#else
		return false;
		#end
	}

	// port: handle kinds and host events (hxmc.rt.Uv)
	static inline final HK_IDLE = 0;
	static inline final HK_PREPARE = 1;
	static inline final HK_CHECK = 2;
	static inline final HK_TIMER = 3;
	static inline final HK_ASYNC = 4;
	static inline final HK_TCP = 5;
	static inline final HK_UDP = 6;
	static inline final HK_PIPE = 7;
	static inline final HK_TTY = 8;
	static inline final HK_SIGNAL = 9;
	static inline final HK_FS_EVENT = 11;
	static inline final HK_FS_POLL = 12;
	static inline final EV_CLOSE = 0;
	static inline final EV_CB = 1;
	static inline final EV_REQ = 2;
	static inline final EV_CONNECTION = 3;
	static inline final EV_ALLOC = 4;
	static inline final EV_READ = 5;
	static inline final EV_EXIT = 6;
	static inline final EV_UDP_RECV = 7;
	static inline final EV_FS_EVENT = 8;
	static inline final EV_FS_POLL = 9;

	static function i64():Int64 return Int64.make(Uv.i64Hi(), Uv.i64Lo());

	// port: ---- luv's callback bookkeeping (Handle.set_reference, Request.set_callback)
	static final handleCallbacks = new Map<Int, LuvHandleCallbacks>();
	static final requestCallbacks = new Map<Int, Int->Void>();

	static function callbacks(id:Int):LuvHandleCallbacks {
		var c = handleCallbacks.get(id);
		if (c == null) {
			c = new LuvHandleCallbacks();
			handleCallbacks.set(id, c);
		}
		return c;
	}

	// port: the host's event dispatcher, passed to `uv_run` (see the module comment).
	static function dispatch(id:Int, event:Int, a:Int, b:Dynamic):Void {
		switch event {
			case EV_CLOSE:
				var c = handleCallbacks.get(id);
				handleCallbacks.remove(id);
				if (c != null && c.close != null) c.close();
			case EV_REQ:
				var f = requestCallbacks.get(id);
				requestCallbacks.remove(id);
				if (f != null) f(a);
			case EV_CB:
				var c = handleCallbacks.get(id);
				if (c != null && c.cb != null) c.cb(a);
			case EV_CONNECTION:
				var c = handleCallbacks.get(id);
				if (c != null && c.connection != null) c.connection(a);
			case EV_ALLOC:
				var c = handleCallbacks.get(id);
				Uv.allocSize(c != null && c.allocate != null ? c.allocate(a) : 0);
			case EV_READ | EV_UDP_RECV | EV_FS_EVENT | EV_FS_POLL:
				var c = handleCallbacks.get(id);
				if (c != null && c.data != null) c.data(a, b);
			case EV_EXIT:
				var c = handleCallbacks.get(id);
				if (c != null && c.exit != null) c.exit(i64(), (b : Int));
			case _:
		}
	}

	// port: luv's `Error.catch_exceptions`.
	static function catchExceptions<T>(f:T->Void, v:T):Void {
		try {
			f(v);
		} catch (e:Dynamic) {
			unhandledException(e);
		}
	}

	// port: `Luv.Error.set_on_unhandled_exception`: set by `EvalMain.create`, then by `UVError.setOnUnhandledException`.
	public static var exceptionHandler:Dynamic->Void = e -> throw e;

	static function unhandledException(e:Dynamic):Void exceptionHandler(e);

	// port: uv_run waits without the Eval lock (luv's `Loop.run` releases OCaml's
	// runtime lock) and its callbacks take it. A callback that activates the
	// lock (by starting a thread) holds it until it returns.
	static function loopRun(loop:Int, mode:Int):Bool {
		EvalLock.leave();
		var r = try Uv.loopRun(loop, mode, lockedDispatch) catch (e:Dynamic) {
			EvalLock.enter();
			throw e;
		}
		EvalLock.enter();
		return r;
	}

	static function lockedDispatch(id:Int, event:Int, a:Int, b:Dynamic):Void {
		EvalLock.enter();
		try dispatch(id, event, a, b)
		catch (e:Dynamic) {
			EvalLock.leave();
			throw e;
		}
		EvalLock.leave();
	}

	// port: ---- encoders/decoders

	public static function encodeUvError(code:Int):Value return Uv.errIndex(code).vint();

	public static function decodeUvError(v:Value):Int {
		var i = EvalDecode.decodeInt(v);
		if (i < 0 || i > 81 || i == 24) return EvalExceptions.unexpectedValue(v, "eval.luv.UVError");
		return Uv.errCode(i);
	}

	static function luvException(e:Int):Value {
		var vi = EvalEncode.encodeInstance(EvalHash.key_eval_luv_LuvException);
		return switch vi {
			case VInstance(i):
				var msg = EvalString.createUnknown(Uv.strerror(e));
				var error = encodeUvError(e);
				EvalMisc.setInstanceField(i, EvalHash.key_exception_message, msg);
				EvalMisc.setInstanceField(i, EvalHash.key_native_exception, error);
				EvalMisc.setInstanceField(i, EvalHash.key_error, error);
				var ctx = EvalContext.getCtx();
				var eval = EvalContext.getEval(ctx);
				if (eval.env != null) {
					var stack = EvalStackTrace.makeStackValue(EvalContext.callStack(eval));
					EvalMisc.setInstanceField(i, EvalHash.key_native_stack, stack);
				}
				vi;
			case _:
				Globals.die("", "evalLuv.ml:luv_exception");
		}
	}

	static function ok(v:Value):Value return EvalEncode.encodeEnumValue(EvalHash.key_eval_luv_Result, 0, vector(v), null);

	static function error(code:Int):Value return EvalEncode.encodeEnumValue(EvalHash.key_eval_luv_Result, 1, vector(encodeUvError(code)), null);

	// port: `encode_result f` of a host result: a negative code is an error.
	static function encodeResult(r:Int, f:Int->Value):Value return r < 0 ? error(r) : ok(f(r));

	static function encodeUnitResult(r:Int):Value return r < 0 ? error(r) : ok(VNull);

	// port: `encode_callback`: the callback receiving one `Result`.
	static function encodeCallback(vCallback:Value):Value->Void {
		var cb = EvalMisc.prepareCallback(vCallback, 1);
		return result -> cb([result]);
	}

	static function resolveResult(r:Int):Int {
		if (r < 0) EvalContext.throwValue(luvException(r), Globals.nullPos);
		return r;
	}

	static function decodeLoop(v:Value):Int {
		return switch v {
			case VHandle(HLoop(t)): t;
			case v: EvalExceptions.unexpectedValue(v, "eval.luv.Loop");
		}
	}

	static function decodeLuvHandle(v:Value):Int {
		return switch EvalDecode.decodeHandle(v) {
			case HIdle(t) | HTimer(t) | HAsync(t) | HPipe(t) | HTcp(t) | HTty(t) | HUdp(t) | HSignal(t) | HProcess(t) | HFsEvent(t) |
				HFsPoll(t) | HPrepare(t) | HCheck(t): t;
			/* TODO
				| HPoll t -> Handle.coerce t
			 */
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.Handle");
		}
	}

	static function decodeSocketHandle(v:Value):Int {
		return switch EvalDecode.decodeHandle(v) {
			case HTcp(t) | HUdp(t) | HPipe(t): t;
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.Handle.SocketHandle");
		}
	}

	static function decodeStream(v:Value):Int {
		return switch EvalDecode.decodeHandle(v) {
			case HTcp(t) | HTty(t) | HPipe(t): t;
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.Stream");
		}
	}

	static function decodeIdle(v:Value):Int return switch v {
		case VHandle(HIdle(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Idle");
	}

	static function decodeTimer(v:Value):Int return switch v {
		case VHandle(HTimer(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Timer");
	}

	static function decodeAsync(v:Value):Int return switch v {
		case VHandle(HAsync(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Async");
	}

	static function decodeBuffer(v:Value):LuvBuffer return switch v {
		case VHandle(HBuffer(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Buffer");
	}

	static function decodeBuffers(v:Value):Array<LuvBuffer> return EvalDecode.decodeArray(v).map(decodeBuffer);

	static function encodeBuffer(b:LuvBuffer):Value return VHandle(HBuffer(b));

	static function decodeSockaddr(v:Value):Bytes {
		return switch EvalDecode.decodeHandle(v) {
			case HSockAddr(t): t;
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.SockAddr");
		}
	}

	static function encodeSockaddr(h:Bytes):Value return VHandle(HSockAddr(h));

	static function decodeTcp(v:Value):Int return switch v {
		case VHandle(HTcp(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Tcp");
	}

	static function decodeUdp(v:Value):Int return switch v {
		case VHandle(HUdp(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Udp");
	}

	static function encodeUdp(udp:Int):Value return VHandle(HUdp(udp));

	static function decodeUdpMembership(v:Value):Bool {
		return switch EvalDecode.decodeInt(v) {
			case 0: false; // port: LEAVE_GROUP
			case 1: true; // port: JOIN_GROUP
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.Udp.UdpMembership");
		}
	}

	// port: `Sockaddr.Socket_type.to_c` of `decode_socket_type`.
	static function decodeSocketType(v:Value):Int {
		var e = EvalDecode.decodeEnum(v);
		return switch [e.index, e.args] {
			case [0, []]: Uv.constant(4, 0); // port: STREAM
			case [1, []]: Uv.constant(4, 1); // port: DGRAM
			case [2, []]: Uv.constant(4, 2); // port: RAW
			case [3, [v]]: EvalDecode.decodeInt(v); // port: OTHER
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.SockAddr.SocketType");
		}
	}

	// port: `Sockaddr.Address_family.to_c` of `decode_address_family`.
	static function decodeAddressFamily(v:Value):Int {
		var e = EvalDecode.decodeEnum(v);
		return switch [e.index, e.args] {
			case [0, []]: Uv.constant(3, 0); // port: UNSPEC
			case [1, []]: Uv.constant(3, 1); // port: INET
			case [2, []]: Uv.constant(3, 2); // port: INET6
			case [3, [v]]: EvalDecode.decodeInt(v); // port: OTHER
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.SockAddr.AddressType");
		}
	}

	// port: `encode_address_family` of `Address_family.from_c`.
	static function encodeAddressFamily(a:Int):Value {
		var r = if (a == Uv.constant(3,
			0)) {index: 0, args: []} else if (a == Uv.constant(3,
			1)) {index: 1, args: []} else if (a == Uv.constant(3, 2)) {index: 2, args: []} else {index: 3, args: [a.vint()]};
		return EvalEncode.encodeEnumValue(EvalHash.key_eval_luv_AddressFamily, r.index, Vector.fromArrayCopy(r.args), null);
	}

	// port: `encode_socket_type` of `Socket_type.from_c`.
	static function encodeSocketType(a:Int):Value {
		var r = if (a == Uv.constant(4,
			0)) {index: 0, args: []} else if (a == Uv.constant(4,
			1)) {index: 1, args: []} else if (a == Uv.constant(4, 2)) {index: 2, args: []} else {index: 3, args: [a.vint()]};
		return EvalEncode.encodeEnumValue(EvalHash.key_eval_luv_SocketType, r.index, Vector.fromArrayCopy(r.args), null);
	}

	static function decodePipe(v:Value):Int return switch v {
		case VHandle(HPipe(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Pipe");
	}

	static function decodeTty(v:Value):Int return switch v {
		case VHandle(HTty(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Tty");
	}

	static function decodeFile(v:Value):Int return switch v {
		case VHandle(HFile(f)): f;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.File");
	}

	static function decodeSignal(v:Value):Int return switch v {
		case VHandle(HSignal(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Signal");
	}

	static function decodeProcess(v:Value):Int return switch v {
		case VHandle(HProcess(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Process");
	}

	static function decodePrepare(v:Value):Int return switch v {
		case VHandle(HPrepare(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Prepare");
	}

	static function decodeCheck(v:Value):Int return switch v {
		case VHandle(HCheck(t)): t;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Check");
	}

	// port: `File.Mode.to_c` of `decode_file_mode`.
	static function decodeFileMode(v:Value):Int {
		var e = EvalDecode.decodeEnum(v);
		return switch [e.index, e.args] {
			case [i, []] if (i >= 0 && i <= 21): Uv.constant(1, i);
			case [22, [v2]]: EvalDecode.decodeInt(v2); // port: NUMERIC
			case _: EvalExceptions.unexpectedValue(v, "eval.luv.File.FileMode");
		}
	}

	// port: `Mode.list_to_c` of `decode_file_mode_list`.
	static function decodeFileModeList(v:Value):Int {
		var r = 0;
		for (m in EvalDecode.decodeArray(v).map(decodeFileMode)) r |= m;
		return r;
	}

	static function decodeFileRequest(v:Value):Int return switch v {
		case VHandle(HFileRequest(r)): r;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.File.FileRequest");
	}

	static function encodeTimespec(b:Bytes, i:Int):Value {
		return EvalEncode.encodeObj([
			{name: EvalHash.key_sec, value: VInt64(b.getInt64(8 * i))},
			{name: EvalHash.key_nsec, value: VInt64(b.getInt64(8 * (i + 1)))}
		]);
	}

	static function decodeDir(v:Value):Int return switch v {
		case VHandle(HDir(dir)): dir;
		case _: EvalExceptions.unexpectedValue(v, "eval.luv.Dir");
	}

	// port: `encode_dirent` of a host dirent (kind index, name).
	static function encodeDirent(kind:Int, name:Bytes):Value {
		return EvalEncode.encodeObj([
			{name: EvalHash.key_kind, value: kind.vint()},
			{name: EvalHash.key_name, value: name.vnativeString()}
		]);
	}

	static function encodeScandir(req:Int):Value {
		return EvalEncode.encodeObj([
			{
				name: EvalHash.key_next,
				value: EvalEncode.vfun0(() -> {
					// port: Directory_scan.next: the scan stops at the end
					var e = Uv.fsScandirNext(req);
					if (e == null) {
						Uv.fsCleanup(req);
						VNull;
					} else
						encodeDirent(e[0], e[1]);
				})
			},
			{
				name: EvalHash.key_end,
				value: EvalEncode.vfun0(() -> {
					Uv.fsCleanup(req);
					VNull;
				})
			}
		]);
	}

	static function decodeIntFlags(v:Value):Array<Int> {
		if (v.match(VNull)) return [];
		return EvalDecode.decodeArray(v).map(EvalDecode.decodeInt);
	}

	// port: `Open_flag.to_c` of `decode_file_open_flag`.
	static function decodeFileOpenFlag(v:Value):Int {
		var i = EvalDecode.decodeInt(v);
		if (i < 0 || i > 20) return EvalExceptions.unexpectedValue(v, "eval.luv.File.FileOpenFlag");
		return Uv.constant(0, i);
	}

	static function encodeFileStat(s:Bytes):Value {
		inline function u(i:Int):Value return VUInt64(s.getInt64(8 * i));
		return EvalEncode.encodeObj([
			{name: EvalHash.key_dev, value: u(0)},
			{name: EvalHash.key_mode, value: VHandle(HFileModeNumeric(s.getInt32(8)))},
			{name: EvalHash.key_nlink, value: u(2)},
			{name: EvalHash.key_uid, value: u(3)},
			{name: EvalHash.key_gid, value: u(4)},
			{name: EvalHash.key_rdev, value: u(5)},
			{name: EvalHash.key_ino, value: u(6)},
			{name: EvalHash.key_size, value: u(7)},
			{name: EvalHash.key_blksize, value: u(8)},
			{name: EvalHash.key_blocks, value: u(9)},
			{name: EvalHash.key_flags, value: u(10)},
			{name: EvalHash.key_gen, value: u(11)},
			{name: EvalHash.key_atim, value: encodeTimespec(s, 12)},
			{name: EvalHash.key_mtim, value: encodeTimespec(s, 14)},
			{name: EvalHash.key_ctim, value: encodeTimespec(s, 16)},
			{name: EvalHash.key_birthtim, value: encodeTimespec(s, 18)},
		]);
	}

	static function encodeFileStatfs(s:Bytes):Value {
		inline function u(i:Int):Value return VUInt64(s.getInt64(8 * i));
		return EvalEncode.encodeObj([
			{name: EvalHash.key_type, value: u(0)},
			{name: EvalHash.key_bsize, value: u(1)},
			{name: EvalHash.key_blocks, value: u(2)},
			{name: EvalHash.key_bfree, value: u(3)},
			{name: EvalHash.key_bavail, value: u(4)},
			{name: EvalHash.key_files, value: u(5)},
			{name: EvalHash.key_ffree, value: u(6)},
			{name: EvalHash.key_fspare, value: EvalEncode.encodeArray([u(7), u(8), u(9), u(10)])}
		]);
	}

	static function decodeFsEvent(v:Value):Int return switch v {
		case VHandle(HFsEvent(e)): e;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.FsEvent");
	}

	static function decodeMutex(v:Value):LuvMutex return switch v {
		case VHandle(HMutex(m)): m;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Mutex");
	}

	static function decodeRwlock(v:Value):LuvRwLock return switch v {
		case VHandle(HRwLock(l)): l;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.RwLock");
	}

	static function decodeSemaphore(v:Value):LuvSemaphore return switch v {
		case VHandle(HSemaphore(s)): s;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Semaphore");
	}

	static function decodeCondition(v:Value):LuvCondition return switch v {
		case VHandle(HCondition(c)): c;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Condition");
	}

	static function decodeBarrier(v:Value):LuvBarrier return switch v {
		case VHandle(HBarrier(b)): b;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.Barrier");
	}

	static function decodeFsPoll(v:Value):Int return switch v {
		case VHandle(HFsPoll(p)): p;
		case v: EvalExceptions.unexpectedValue(v, "eval.luv.FsPoll");
	}

	static function f(name:String, value:Value):{name:String, value:Value}
		return {name: name, value: value};

	// port: buffers as one Bytes plus their sizes, for the host's iovecs.
	static function flatten(l:Array<LuvBuffer>):{data:Bytes, sizes:Array<Int>} {
		var total = 0;
		for (b in l) total += b.length;
		var data = Bytes.alloc(total);
		var pos = 0;
		for (b in l) {
			data.blit(pos, b.bytes, b.offset, b.length);
			pos += b.length;
		}
		return {data: data, sizes: [for (b in l) b.length]};
	}

	// port: copies `n` bytes read into the host request's memory to the buffers, in order.
	static function copyOut(req:Int, l:Array<LuvBuffer>, n:Int):Void {
		var src = 0;
		for (b in l) {
			if (src >= n) break;
			var len = b.length < n - src ? b.length : n - src;
			Uv.reqCopyOut(req, b.bytes, b.offset, src, len);
			src += len;
		}
	}

	// port: ---- UVError
	public static final uvErrorFields:Array<{name:String, value:Value}> = [
		f("toString", EvalEncode.vfun1(v -> {
			var e = decodeUvError(v);
			EvalString.createUnknown(Uv.strerror(e));
		})),
		f("errName", EvalEncode.vfun1(v -> {
			var e = decodeUvError(v);
			EvalString.createUnknown(Uv.errName(e));
		})),
		f("translateSysError", EvalEncode.vfun1(v -> {
			var e = EvalDecode.decodeInt(v);
			encodeUvError(Uv.translateSysError(e));
		})),
		f("setOnUnhandledException", EvalEncode.vfun1(v -> {
			var cb = EvalMisc.prepareCallback(v, 1);
			exceptionHandler = ex -> {
				var msg = if (Std.isOfType(ex, core.Error.TypingError)) {
						var err = (ex : core.Error.TypingError).error;
						switch err.errMessage {
							// TODO beware of err_sub here
							case Custom(msg):
								// Eval interpreter rethrows runtime exceptions as `Custom "Exception message\nException stack"`
								var i = msg.indexOf("\n");
								i < 0 ? msg : msg.substr(0, i);
							case _:
								var messages = [];
								core.Error.recurseError((depth, err) -> {
									var cm = core.Message.makeMessage(EvalContext.getCtx().isMacro, core.Error.errorMsg(err.errMessage),
										err.errPos, depth, MKError);
									var ectx = compiler.MessageReporting.createErrorContext(false);
									switch compiler.MessageReporting.messageString(ectx, cm) {
										case null:
										case str: messages.unshift(str);
									}
								}, err);
								messages.reverse();
								messages.join("\n");
						}
					} else Std.string(ex);
				var e = EvalMisc.createHaxeException(msg, EvalContext.getEval(EvalContext.getCtx()).exceptionStack);
				cb([e]);
			};
			VNull;
		})),
	];

	// port: ---- Loop
	public static final loopFields:Array<{name:String, value:Value}> = [
		f("run", EvalEncode.vfun2((v1, v2) -> {
			var loop = decodeLoop(v1);
			var mode = switch EvalDecode.decodeInt(v2) {
					case 0: 0; // port: DEFAULT
					case 1: 1; // port: ONCE
					case 2: 2; // port: NOWAIT
					case _: EvalExceptions.unexpectedValue(v2, "valid loop run mode");
				}
			loopRun(loop, mode).vbool();
		})),
		f("stop", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			Uv.loopStop(loop);
			VNull;
		})),
		f("init", EvalEncode.vfun0(() -> {
			encodeResult(Uv.loopInit(), l -> VHandle(HLoop(l)));
		})),
		f("close", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			encodeUnitResult(Uv.loopClose(loop));
		})),
		f("alive", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			Uv.loopAlive(loop).vbool();
		})),
		f("defaultLoop", EvalEncode.vfun0(() -> {
			VHandle(HLoop(Uv.loopDefault()));
		})),
		f("libraryShutdown", EvalEncode.vfun0(() -> {
			Uv.libraryShutdown();
			VNull;
		})),
		f("now", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			Uv.loopNow(loop);
			VUInt64(i64());
		})),
		f("updateTime", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			Uv.loopUpdateTime(loop);
			VNull;
		})),
	];

	public static final loopOptionFields:Array<{name:String, value:Value}> = [f("sigprof", Uv.constant(5, 9).vint())];

	// port: ---- Handle
	public static final handleFields:Array<{name:String, value:Value}> = [
		f("close", EvalEncode.vfun2((v1, v2) -> {
			var handle = decodeLuvHandle(v1);
			var cb = EvalMisc.prepareCallback(v2, 0);
			// port: Handle.close: nothing when already closing
			if (!Uv.handleIsClosing(handle)) {
				callbacks(handle).close = () -> catchExceptions(_ -> cb([]), null);
				Uv.handleClose(handle);
			}
			VNull;
		})),
		f("isActive", EvalEncode.vfun1(v -> {
			var handle = decodeLuvHandle(v);
			Uv.handleIsActive(handle).vbool();
		})),
		f("isClosing", EvalEncode.vfun1(v -> {
			var handle = decodeLuvHandle(v);
			Uv.handleIsClosing(handle).vbool();
		})),
		f("ref", EvalEncode.vfun1(v -> {
			var handle = decodeLuvHandle(v);
			Uv.handleRef(handle);
			VNull;
		})),
		f("unref", EvalEncode.vfun1(v -> {
			var handle = decodeLuvHandle(v);
			Uv.handleUnref(handle);
			VNull;
		})),
		f("hasRef", EvalEncode.vfun1(v -> {
			var handle = decodeLuvHandle(v);
			Uv.handleHasRef(handle).vbool();
		})),
		f("sendBufferSize", EvalEncode.vfun1(v -> {
			var handle = decodeSocketHandle(v);
			encodeResult(Uv.bufferSize(handle, true, 0), i -> i.vint());
		})),
		f("setSendBufferSize", EvalEncode.vfun2((v1, v2) -> {
			var handle = decodeSocketHandle(v1);
			var size = EvalDecode.decodeInt(v2);
			encodeUnitResult(Uv.bufferSize(handle, true, size));
		})),
		f("recvBufferSize", EvalEncode.vfun1(v -> {
			var handle = decodeSocketHandle(v);
			encodeResult(Uv.bufferSize(handle, false, 0), i -> i.vint());
		})),
		f("setRendBufferSize", EvalEncode.vfun2((v1, v2) -> {
			var handle = decodeSocketHandle(v1);
			var size = EvalDecode.decodeInt(v2);
			encodeUnitResult(Uv.bufferSize(handle, false, size));
		})),
	];

	// port: ---- Idle, Prepare, Check (luv's Loop_watcher)

	static function watcherFields(kind:Int, decode:Value->Int, wrap:Int->Vhandle):Array<{name:String, value:Value}> {
		return [
			f("init", EvalEncode.vfun1(v -> {
				var loop = decodeLoop(v);
				encodeResult(Uv.handleInit(kind, loop, 0, 0), i -> VHandle(wrap(i)));
			})),
			f("start", EvalEncode.vfun2((v1, v2) -> {
				var w = decode(v1);
				var cb = EvalMisc.prepareCallback(v2, 0);
				callbacks(w).cb = _ -> catchExceptions(_ -> cb([]), null);
				encodeUnitResult(Uv.watcherStart(w));
			})),
			f("stop", EvalEncode.vfun1(v -> {
				var w = decode(v);
				encodeUnitResult(Uv.watcherStop(w));
			})),
		];
	}

	public static final idleFields = watcherFields(HK_IDLE, decodeIdle, i -> HIdle(i));

	// port: ---- Timer
	public static final timerFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			encodeResult(Uv.handleInit(HK_TIMER, loop, 0, 0), i -> VHandle(HTimer(i)));
		})),
		f("start", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var timer = decodeTimer(v1);
			var cb = EvalMisc.prepareCallback(v2, 0);
			var timeout = EvalDecode.decodeInt(v3);
			var repeat = EvalDecode.defaultInt(v4, 0);
			callbacks(timer).cb = _ -> catchExceptions(_ -> cb([]), null);
			encodeUnitResult(Uv.timerStart(timer, timeout, repeat));
		})),
		f("stop", EvalEncode.vfun1(v -> {
			var timer = decodeTimer(v);
			encodeUnitResult(Uv.timerStop(timer));
		})),
		f("again", EvalEncode.vfun1(v -> {
			var timer = decodeTimer(v);
			encodeUnitResult(Uv.timerAgain(timer));
		})),
		f("set_repeat", EvalEncode.vfun2((v1, v2) -> {
			var timer = decodeTimer(v1);
			var repeat = EvalDecode.decodeInt(v2);
			Uv.timerSetRepeat(timer, repeat);
			repeat.vint();
		})),
		f("get_repeat", EvalEncode.vfun1(v1 -> {
			var timer = decodeTimer(v1);
			Uv.timerGetRepeat(timer).vint();
		})),
		f("get_dueIn", EvalEncode.vfun1(v1 -> {
			var timer = decodeTimer(v1);
			Uv.timerGetDueIn(timer).vint();
		})),
	];

	// port: ---- Async
	public static final asyncFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun2((v1, v2) -> {
			var loop = decodeLoop(v1);
			var cb = EvalMisc.prepareCallback(v2, 1);
			var r = Uv.handleInit(HK_ASYNC, loop, 0, 0);
			if (r >= 0) {
				var async = r;
				callbacks(async).cb = _ -> catchExceptions(_ -> cb([VHandle(HAsync(async))]), null);
			}
			encodeResult(r, i -> VHandle(HAsync(i)));
		})),
		f("send", EvalEncode.vfun1(v -> {
			var async = decodeAsync(v);
			encodeUnitResult(Uv.asyncSend(async));
		})),
	];

	// port: ---- Buffer (luv's buffer.ml over Bigarray)

	static function charOfInt(i:Int):Int {
		if (i < 0 || i > 255) throw new InvalidArgument("char_of_int");
		return i;
	}

	static function bufferGet(safe:Bool):Value {
		return EvalEncode.vfun2((v1, v2) -> {
			var buffer = decodeBuffer(v1);
			var index = EvalDecode.decodeInt(v2);
			if (safe && (index < 0 || index >= buffer.length)) throw new InvalidArgument("index out of bounds");
			buffer.bytes.get(buffer.offset + index).vint();
		});
	}

	static function bufferSet(safe:Bool):Value {
		return EvalEncode.vfun3((v1, v2, v3) -> {
			var buffer = decodeBuffer(v1);
			var index = EvalDecode.decodeInt(v2);
			var byte = EvalDecode.decodeInt(v3);
			var c = charOfInt(byte);
			if (safe && (index < 0 || index >= buffer.length)) throw new InvalidArgument("index out of bounds");
			buffer.bytes.set(buffer.offset + index, c);
			v3;
		});
	}

	static function bufferFromBytes(b:Bytes):LuvBuffer {
		var buffer = LuvBuffer.create(b.length);
		buffer.bytes.blit(0, b, 0, b.length);
		return buffer;
	}

	static function bufferToBytes(buffer:LuvBuffer):Bytes return buffer.bytes.sub(buffer.offset, buffer.length);

	static function bufferDrop(l:Array<LuvBuffer>, count:Int):Array<LuvBuffer> {
		if (count <= 0) return l;
		if (l.length == 0) return l;
		var first = l[0];
		var size = first.length;
		if (count < size) return [first.sub(count, size - count)].concat(l.slice(1));
		return bufferDrop(l.slice(1), count - size);
	}

	public static final bufferFields:Array<{name:String, value:Value}> = [
		f("create", EvalEncode.vfun1(v -> {
			var size = EvalDecode.decodeInt(v);
			if (size < 0) throw new InvalidArgument("Bigarray.create: negative dimension");
			encodeBuffer(LuvBuffer.create(size));
		})),
		f("fromNativeString", EvalEncode.vfun1(v -> {
			var s = EvalDecode.decodeNativeString(v);
			encodeBuffer(bufferFromBytes(s));
		})),
		f("fromString", EvalEncode.vfun1(v -> {
			var s = EvalDecode.decodeString(v);
			encodeBuffer(bufferFromBytes(Bytes.ofString(s)));
		})),
		f("fromBytes", EvalEncode.vfun1(v -> {
			var b = EvalDecode.decodeBytes(v);
			encodeBuffer(bufferFromBytes(b));
		})),
		f("totalSize", EvalEncode.vfun1(v -> {
			var l = decodeBuffers(v);
			var total = 0;
			for (b in l) total += b.length;
			total.vint();
		})),
		f("drop", EvalEncode.vfun2((v1, v2) -> {
			var l = decodeBuffers(v1);
			var count = EvalDecode.decodeInt(v2);
			EvalEncode.encodeArray(bufferDrop(l, count).map(encodeBuffer));
		})),
		f("size",
			EvalEncode.vfun1(v -> {
				var buffer = decodeBuffer(v);
				buffer.length.vint();
			})),
		f("get", bufferGet(true)),
		f("unsafeGet", bufferGet(false)),
		f("set", bufferSet(true)),
		f("unsafeSet", bufferSet(false)),
		f("sub", EvalEncode.vfun3((v1, v2, v3) -> {
			var buffer = decodeBuffer(v1);
			var offset = EvalDecode.decodeInt(v2);
			var length = EvalDecode.decodeInt(v3);
			encodeBuffer(buffer.sub(offset, length));
		})),
		f("blit", EvalEncode.vfun2((v1, v2) -> {
			var buffer = decodeBuffer(v1);
			var destination = decodeBuffer(v2);
			if (buffer.length != destination.length) throw new InvalidArgument("Bigarray.blit: dimension mismatch");
			destination.bytes.blit(destination.offset, buffer.bytes, buffer.offset, buffer.length);
			VNull;
		})),
		f("fill", EvalEncode.vfun2((v1, v2) -> {
			var buffer = decodeBuffer(v1);
			var byte = EvalDecode.decodeInt(v2);
			buffer.bytes.fill(buffer.offset, buffer.length, charOfInt(byte));
			VNull;
		})),
		f("toString", EvalEncode.vfun1(v -> {
			var buffer = decodeBuffer(v);
			EvalString.createUnknown(bufferToBytes(buffer).toString());
		})),
		f("toNativeString", EvalEncode.vfun1(v -> {
			var buffer = decodeBuffer(v);
			bufferToBytes(buffer).vnativeString();
		})),
		f("toBytes", EvalEncode.vfun1(v -> {
			var buffer = decodeBuffer(v);
			EvalEncode.encodeBytes(bufferToBytes(buffer));
		})),
		f("blitToBytes", EvalEncode.vfun3((v1, v2, v3) -> {
			var buffer = decodeBuffer(v1);
			var destination = EvalDecode.decodeBytes(v2);
			var offset = EvalDecode.decodeInt(v3);
			destination.blit(offset, buffer.bytes, buffer.offset, buffer.length);
			VNull;
		})),
		f("blitFromBytes", EvalEncode.vfun3((v1, v2, v3) -> {
			var buffer = decodeBuffer(v1);
			var source = EvalDecode.decodeBytes(v2);
			var offset = EvalDecode.decodeInt(v3);
			// port: memcpy of Bytes.length bytes from source + offset
			buffer.bytes.blit(buffer.offset, source, offset, source.length);
			VNull;
		})),
		f("blitFromString", EvalEncode.vfun3((v1, v2, v3) -> {
			var buffer = decodeBuffer(v1);
			var source = EvalDecode.decodeNativeString(v2);
			var offset = EvalDecode.decodeInt(v3);
			buffer.bytes.blit(buffer.offset, source, offset, source.length);
			VNull;
		})),
	];

	// port: ---- SockAddr

	static function sockaddrFrom(host:String, port:Int, v6:Bool):Value {
		var storage = Bytes.alloc(Uv.sockaddrSize());
		var r = Uv.sockaddrIp(host, port, v6, storage);
		return encodeResult(r, _ -> encodeSockaddr(storage));
	}

	public static final sockaddrFields:Array<{name:String, value:Value}> = [
		f("get_port", EvalEncode.vfun1(v -> {
			var a = decodeSockaddr(v);
			var port = Uv.sockaddrPort(a);
			port < 0 ? VNull : port.vint();
		})),
		f("ipv4", EvalEncode.vfun2((v1, v2) -> {
			var host = EvalDecode.decodeString(v1);
			var port = EvalDecode.decodeInt(v2);
			sockaddrFrom(host, port, false);
		})),
		f("ipv6", EvalEncode.vfun2((v1, v2) -> {
			var host = EvalDecode.decodeString(v1);
			var port = EvalDecode.decodeInt(v2);
			sockaddrFrom(host, port, true);
		})),
		f("toString", EvalEncode.vfun1(v -> {
			var a = decodeSockaddr(v);
			switch Uv.sockaddrToString(a) {
				case null: VString(EvalString.createAscii(""));
				case s: EvalString.createUnknown(s);
			}
		})),
	];

	// port: luv's `Sockaddr.wrap_c_getter`.
	static function sockName(handle:Int, peer:Bool):Value {
		var storage = Bytes.alloc(Uv.sockaddrSize());
		return encodeResult(Uv.sockName(handle, peer, storage), _ -> encodeSockaddr(storage));
	}

	// port: A request whose completion calls `f` with its status, released afterwards.
	static function statusRequest(f:Int->Void):Int {
		var req = Uv.reqNew();
		requestCallbacks.set(req, status -> {
			Uv.reqFree(req);
			f(status);
		});
		return req;
	}

	// port: luv's pattern for a request taking a unit callback: an immediate error calls back directly.
	static function unitRequest(callback:Value->Void, start:Int->Int):Void {
		var req = statusRequest(status -> catchExceptions(callback, encodeUnitResult(status)));
		var r = start(req);
		if (r < 0) {
			requestCallbacks.remove(req);
			Uv.reqFree(req);
			callback(error(r));
		}
	}

	// port: ---- Tcp
	public static final tcpFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun2((v1, v2) -> {
			var loop = decodeLoop(v1);
			var domain = EvalDecode.decodeOptional(decodeAddressFamily, v2);
			var tcp = Uv.handleInit(HK_TCP, loop, domain == null ? -1 : domain, 0);
			encodeResult(tcp, t -> VHandle(HTcp(t)));
		})),
		f("noDelay", EvalEncode.vfun2((v1, v2) -> {
			var tcp = decodeTcp(v1);
			var value = EvalDecode.decodeBool(v2);
			encodeUnitResult(Uv.tcpNoDelay(tcp, value));
		})),
		f("keepAlive", EvalEncode.vfun2((v1, v2) -> {
			var tcp = decodeTcp(v1);
			var value = EvalDecode.decodeOption(EvalDecode.decodeInt, v2);
			encodeUnitResult(value == null ? Uv.tcpKeepAlive(tcp, false, 0) : Uv.tcpKeepAlive(tcp, true, value));
		})),
		f("simultaneousAccepts", EvalEncode.vfun2((v1, v2) -> {
			var tcp = decodeTcp(v1);
			var value = EvalDecode.decodeBool(v2);
			encodeUnitResult(Uv.tcpSimultaneousAccepts(tcp, value));
		})),
		f("bind", EvalEncode.vfun3((v1, v2, v3) -> {
			var tcp = decodeTcp(v1);
			var addr = decodeSockaddr(v2);
			var ipv6only = EvalDecode.decodeOptional(EvalDecode.decodeBool, v3);
			encodeUnitResult(Uv.tcpBind(tcp, addr, ipv6only == true));
		})),
		f("getSockName", EvalEncode.vfun1(v -> {
			var tcp = decodeTcp(v);
			sockName(tcp, false);
		})),
		f("getPeerName", EvalEncode.vfun1(v -> {
			var tcp = decodeTcp(v);
			sockName(tcp, true);
		})),
		f("connect", EvalEncode.vfun3((v1, v2, v3) -> {
			var tcp = decodeTcp(v1);
			var addr = decodeSockaddr(v2);
			var callback = encodeCallback(v3);
			unitRequest(callback, req -> Uv.tcpConnect(tcp, addr, req));
			VNull;
		})),
		f("closeReset", EvalEncode.vfun2((v1, v2) -> {
			var tcp = decodeTcp(v1);
			var callback = encodeCallback(v2);
			// port: TCP.close_reset: the handle is released before the callback
			unitRequest(callback, req -> {
				var r = Uv.tcpCloseReset(tcp, req);
				if (r >= 0) handleCallbacks.remove(tcp);
				r;
			});
			VNull;
		})),
	];

	// port: ---- Udp

	static function encodeUdpFlag(flags:Int):Array<Value> {
		// port: convert_flag folds PARTIAL, MMSG_CHUNK, MMSG_FREE onto the front of the list
		var l = [];
		if (flags & Uv.constant(11, 0) != 0) l.unshift(0.vint());
		if (flags & Uv.constant(11, 1) != 0) l.unshift(1.vint());
		if (flags & Uv.constant(11, 2) != 0) l.unshift(2.vint());
		return l;
	}

	// port: luv's read/recv allocation: the buffer `allocate` returns (Buffer.create by default).
	static function allocator(v:Value):(Int->LuvBuffer) {
		var allocate = EvalDecode.decodeOptional(v -> {
			var cb = EvalMisc.prepareCallback(v, 1);
			(i:Int) -> decodeBuffer(cb([i.vint()]));
		}, v);
		return allocate == null ? LuvBuffer.create : allocate;
	}

	public static final udpFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun3((v1, v2, v3) -> {
			var loop = decodeLoop(v1);
			var domain = EvalDecode.decodeOptional(decodeAddressFamily, v2);
			var recvmmsg = EvalDecode.decodeOptional(EvalDecode.decodeBool, v3);
			var udp = Uv.handleInit(HK_UDP, loop, domain == null ? -1 : domain, recvmmsg == true ? Uv.constant(11, 3) : 0);
			encodeResult(udp, encodeUdp);
		})),
		f("bind", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var udp = decodeUdp(v1);
			var addr = decodeSockaddr(v2);
			var ipv6only = EvalDecode.decodeOptional(EvalDecode.decodeBool, v3);
			var reuseaddr = EvalDecode.decodeOptional(EvalDecode.decodeBool, v4);
			var flags = (ipv6only == true ? Uv.constant(11, 4) : 0) | (reuseaddr == true ? Uv.constant(11, 5) : 0);
			encodeUnitResult(Uv.udpBind(udp, addr, flags));
		})),
		f("connect", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var addr = decodeSockaddr(v2);
			encodeResult(Uv.udpConnect(udp, addr), _ -> encodeUdp(udp));
		})),
		f("getSockName", EvalEncode.vfun1(v -> {
			var udp = decodeUdp(v);
			sockName(udp, false);
		})),
		f("setMembership", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var udp = decodeUdp(v1);
			var group = EvalDecode.decodeString(v2);
			var iface = EvalDecode.decodeString(v3);
			var membership = decodeUdpMembership(v4);
			encodeUnitResult(Uv.udpSetMembership(udp, group, iface, null, membership));
		})),
		f("setSourceMembership", EvalEncode.vfun5((v1, v2, v3, v4, v5) -> {
			var udp = decodeUdp(v1);
			var group = EvalDecode.decodeString(v2);
			var iface = EvalDecode.decodeString(v3);
			var source = EvalDecode.decodeString(v4);
			var membership = decodeUdpMembership(v5);
			encodeUnitResult(Uv.udpSetMembership(udp, group, iface, source, membership));
		})),
		f("setMulticastLoop", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var value = EvalDecode.decodeBool(v2);
			encodeUnitResult(Uv.udpSetOption(udp, 0, value ? 1 : 0));
		})),
		f("setMulticastTtl", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var value = EvalDecode.decodeInt(v2);
			encodeUnitResult(Uv.udpSetOption(udp, 1, value));
		})),
		f("setMulticastInterface", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var value = EvalDecode.decodeString(v2);
			encodeUnitResult(Uv.udpSetMulticastInterface(udp, value));
		})),
		f("setBroadcast", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var value = EvalDecode.decodeBool(v2);
			encodeUnitResult(Uv.udpSetOption(udp, 2, value ? 1 : 0));
		})),
		f("setTtl", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var value = EvalDecode.decodeInt(v2);
			encodeUnitResult(Uv.udpSetOption(udp, 3, value));
		})),
		f("send", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var udp = decodeUdp(v1);
			var l = decodeBuffers(v2);
			var addr = decodeSockaddr(v3);
			var callback = encodeCallback(v4);
			var d = flatten(l);
			unitRequest(callback, req -> Uv.udpSend(udp, req, d.data, d.sizes, addr));
			VNull;
		})),
		f("trySend", EvalEncode.vfun3((v1, v2, v3) -> {
			var udp = decodeUdp(v1);
			var l = decodeBuffers(v2);
			var addr = decodeSockaddr(v3);
			var d = flatten(l);
			encodeUnitResult(Uv.udpTrySend(udp, d.data, d.sizes, addr));
		})),
		f("recvStart", EvalEncode.vfun3((v1, v2, v3) -> {
			function encode(buf:LuvBuffer, addr:Null<Bytes>, flags:Int):Value {
				return EvalEncode.encodeObj([
					{name: EvalHash.key_data, value: encodeBuffer(buf)},
					{name: EvalHash.key_addr, value: EvalEncode.encodeOption(encodeSockaddr, addr)},
					{name: EvalHash.key_flags, value: EvalEncode.encodeArray(encodeUdpFlag(flags))}
				]);
			}
			var udp = decodeUdp(v1);
			var callback = encodeCallback(v2);
			var allocate = allocator(v3);
			// port: UDP.recv_start
			var lastAllocatedBuffer:Null<LuvBuffer> = null;
			var c = callbacks(udp);
			c.allocate = size -> {
				var buffer = allocate(size);
				lastAllocatedBuffer = buffer;
				buffer.length;
			};
			c.data = (nreadOrError, b) -> {
				var maybeBuffer = lastAllocatedBuffer;
				lastAllocatedBuffer = null;
				if (nreadOrError < 0) callback(error(nreadOrError))
				else {
					var length = nreadOrError;
					if (maybeBuffer == null) Globals.die("", "UDP.recv_start");
					var buffer = maybeBuffer.length <= length ? maybeBuffer : maybeBuffer.sub(0, length);
					var a:Array<Dynamic> = b;
					var data:Bytes = a[0];
					buffer.bytes.blit(buffer.offset, data, 0, length < buffer.length ? length : buffer.length);
					catchExceptions(callback, ok(encode(buffer, a[1], a[2])));
				}
			};
			var r = Uv.udpRecvStart(udp);
			if (r < 0) callback(error(r));
			VNull;
		})),
		f("recvStop", EvalEncode.vfun1(v -> {
			var udp = decodeUdp(v);
			encodeUnitResult(Uv.udpRecvStop(udp));
		})),
		f("getSendQueueSize", EvalEncode.vfun1(v -> {
			var udp = decodeUdp(v);
			Uv.udpSendQueue(udp, false).vint();
		})),
		f("getSendQueueCount", EvalEncode.vfun1(v -> {
			var udp = decodeUdp(v);
			Uv.udpSendQueue(udp, true).vint();
		})),
	];

	public static final connectedUdpFields:Array<{name:String, value:Value}> = [
		f("disconnect", EvalEncode.vfun1(v -> {
			var udp = decodeUdp(v);
			encodeUnitResult(Uv.udpConnect(udp, null));
		})),
		f("getPeerName", EvalEncode.vfun1(v -> {
			var udp = decodeUdp(v);
			sockName(udp, true);
		})),
		f("send", EvalEncode.vfun3((v1, v2, v3) -> {
			var udp = decodeUdp(v1);
			var l = decodeBuffers(v2);
			var callback = encodeCallback(v3);
			var d = flatten(l);
			unitRequest(callback, req -> Uv.udpSend(udp, req, d.data, d.sizes, null));
			VNull;
		})),
		// port: upstream registers trySend under the name "send" too
		f("send", EvalEncode.vfun2((v1, v2) -> {
			var udp = decodeUdp(v1);
			var l = decodeBuffers(v2);
			var d = flatten(l);
			encodeUnitResult(Uv.udpTrySend(udp, d.data, d.sizes, null));
		})),
	];

	// port: ---- Pipe
	public static final pipeFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun2((v1, v2) -> {
			var loop = decodeLoop(v1);
			var forHandlePassing = EvalDecode.decodeOptional(EvalDecode.decodeBool, v2);
			encodeResult(Uv.handleInit(HK_PIPE, loop, forHandlePassing == true ? 1 : 0, 0), p -> VHandle(HPipe(p)));
		})),
		f("bind", EvalEncode.vfun2((v1, v2) -> {
			var pipe = decodePipe(v1);
			var name = EvalDecode.decodeNativeString(v2);
			encodeUnitResult(Uv.pipeBind(pipe, name));
		})),
		f("connect", EvalEncode.vfun3((v1, v2, v3) -> {
			var pipe = decodePipe(v1);
			var target = EvalDecode.decodeNativeString(v2);
			var callback = encodeCallback(v3);
			unitRequest(callback, req -> {
				Uv.pipeConnect(pipe, target, req);
				0;
			});
			VNull;
		})),
		f("getSockName", EvalEncode.vfun1(v -> {
			var pipe = decodePipe(v);
			switch Uv.pipeName(pipe, false) {
				case null: error(Uv.lastError());
				case s: ok(s.vnativeString());
			}
		})),
		f("getPeerName", EvalEncode.vfun1(v -> {
			var pipe = decodePipe(v);
			switch Uv.pipeName(pipe, true) {
				case null: error(Uv.lastError());
				case s: ok(s.vnativeString());
			}
		})),
		f("pendingInstances", EvalEncode.vfun2((v1, v2) -> {
			var pipe = decodePipe(v1);
			var amount = EvalDecode.decodeInt(v2);
			Uv.pipePendingInstances(pipe, amount);
			VNull;
		})),
		f("receiveHandle", EvalEncode.vfun1(v -> {
			var pipe = decodePipe(v);
			var r = switch Uv.pipePendingType(pipe) {
					case 1: {index: 1, args: [EvalEncode.vfun1(v -> encodeUnitResult(Uv.streamAccept(pipe, decodeTcp(v))))]};
					case 2: {index: 2, args: [EvalEncode.vfun1(v -> encodeUnitResult(Uv.streamAccept(pipe, decodePipe(v))))]};
					case _: {index: 0, args: []};
				}
			EvalEncode.encodeEnumValue(EvalHash.key_eval_luv_ReceiveHandle, r.index, Vector.fromArrayCopy(r.args), null);
		})),
		f("chmod", EvalEncode.vfun2((v1, v2) -> {
			var pipe = decodePipe(v1);
			var mode = switch EvalDecode.decodeInt(v2) {
					case 0: 0; // port: READABLE
					case 1: 1; // port: WRITABLE
					case 2: 2; // port: READABLE, WRITABLE
					case _: EvalExceptions.unexpectedValue(v2, "eval.luv.Pipe.PipeMode");
				}
			encodeUnitResult(Uv.pipeChmod(pipe, mode));
		})),
	];

	// port: ---- Tty
	public static final ttyFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun2((v1, v2) -> {
			var loop = decodeLoop(v1);
			var file = decodeFile(v2);
			encodeResult(Uv.handleInit(HK_TTY, loop, file, 0), tty -> VHandle(HTty(tty)));
		})),
		f("setMode", EvalEncode.vfun2((v1, v2) -> {
			var tty = decodeTty(v1);
			var mode = switch EvalDecode.decodeInt(v2) {
					case 0: 0; // port: NORMAL
					case 1: 1; // port: RAW
					case 2: 2; // port: IO
					case _: EvalExceptions.unexpectedValue(v2, "eval.luv.Tty.TtyMode");
				}
			encodeUnitResult(Uv.ttySetMode(tty, mode));
		})),
		f("resetMode", EvalEncode.vfun0(() -> {
			encodeUnitResult(Uv.ttyResetMode());
		})),
		f("getWinSize", EvalEncode.vfun1(v -> {
			var tty = decodeTty(v);
			switch Uv.ttyGetWinSize(tty) {
				case null: error(Uv.lastError());
				case a: ok(EvalEncode.encodeObj([
						{name: EvalHash.key_width, value: a[0].vint()},
						{name: EvalHash.key_height, value: a[1].vint()}
					]));
			}
		})),
		f("setVTermState", EvalEncode.vfun1(v -> {
			var state = switch EvalDecode.decodeInt(v) {
					case 0: 0; // port: SUPPORTED
					case 1: 1; // port: UNSUPPORTED
					case _: EvalExceptions.unexpectedValue(v, "eval.luv.Tty.VTermState");
				}
			Uv.ttySetVTermState(state);
			VNull;
		})),
		f("getVTermState", EvalEncode.vfun0(() -> {
			encodeResult(Uv.ttyGetVTermState(), state -> state.vint());
		})),
	];

	// port: ---- Stream
	public static final streamFields:Array<{name:String, value:Value}> = [
		f("shutdown", EvalEncode.vfun2((v1, v2) -> {
			var stream = decodeStream(v1);
			var callback = encodeCallback(v2);
			unitRequest(callback, req -> Uv.streamShutdown(stream, req));
			VNull;
		})),
		f("listen", EvalEncode.vfun3((v1, v2, v3) -> {
			var stream = decodeStream(v1);
			var backlog = EvalDecode.decodeOptional(v -> EvalDecode.decodeInt(v), v3);
			var callback = encodeCallback(v2);
			// port: Stream.listen (the default backlog is SOMAXCONN)
			callbacks(stream).connection = status -> catchExceptions(callback, encodeUnitResult(status));
			var r = Uv.streamListen(stream, backlog == null ? 4096 : backlog);
			if (r < 0) callback(error(r));
			VNull;
		})),
		f("accept", EvalEncode.vfun2((v1, v2) -> {
			var server = decodeStream(v1);
			var client = decodeStream(v2);
			encodeUnitResult(Uv.streamAccept(server, client));
		})),
		f("readStart", EvalEncode.vfun3((v1, v2, v3) -> {
			var stream = decodeStream(v1);
			var callback = encodeCallback(v2);
			var allocate = allocator(v3);
			// port: Stream.read_start
			var lastAllocatedBuffer:Null<LuvBuffer> = null;
			var c = callbacks(stream);
			c.allocate = suggestedSize -> {
				var buffer = allocate(suggestedSize);
				lastAllocatedBuffer = buffer;
				buffer.length;
			};
			c.data = (nreadOrError, data) -> {
				var result = if (nreadOrError > 0) {
						var length = nreadOrError;
						var buffer = switch lastAllocatedBuffer {
								case null: Globals.die("", "Stream.read_start");
								case buffer: buffer;
							}
						lastAllocatedBuffer = null;
						var data:Bytes = data;
						buffer.bytes.blit(buffer.offset, data, 0, length);
						var buffer = buffer.length <= length ? buffer : buffer.sub(0, length);
						ok(encodeBuffer(buffer));
					} else {
						lastAllocatedBuffer = null;
						error(nreadOrError == 0 ? Uv.errCode(71) : nreadOrError); // port: Error.result_from_c 0 is `UNKNOWN
					}
				catchExceptions(callback, result);
			};
			var r = Uv.readStart(stream);
			if (r < 0) callback(error(r));
			VNull;
		})),
		f("readStop", EvalEncode.vfun1(v -> {
			var stream = decodeStream(v);
			encodeUnitResult(Uv.readStop(stream));
		})),
		f("write", EvalEncode.vfun3((v1, v2, v3) -> {
			var stream = decodeStream(v1);
			var data = decodeBuffers(v2);
			var cb = EvalMisc.prepareCallback(v3, 2);
			var callback = (result:Value, bytesWritten:Int) -> cb([result, bytesWritten.vint()]);
			write(stream, data, 0, callback);
			VNull;
		})),
		f("write2", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var stream = decodePipe(v1);
			var data = decodeBuffers(v2);
			var cb = EvalMisc.prepareCallback(v4, 2);
			var callback = (result:Value, bytesWritten:Int) -> cb([result, bytesWritten.vint()]);
			var e = EvalDecode.decodeEnum(v3);
			switch [e.index, e.args] {
				case [0, [vh]]: write(stream, data, decodeTcp(vh), callback);
				case [1, [vh]]: write(stream, data, decodePipe(vh), callback);
				case _: EvalExceptions.unexpectedValue(v3, "eval.luv.Stream.SendHandle");
			}
			VNull;
		})),
		f("tryWrite", EvalEncode.vfun2((v1, v2) -> {
			var stream = decodeStream(v1);
			var data = decodeBuffers(v2);
			var d = flatten(data);
			encodeResult(Uv.streamTryWrite(stream, d.data, d.sizes), n -> n.vint());
		})),
		f("isReadable", EvalEncode.vfun1(v -> {
			var stream = decodeStream(v);
			Uv.streamIsReadable(stream).vbool();
		})),
		f("isWritable", EvalEncode.vfun1(v -> {
			var stream = decodeStream(v);
			Uv.streamIsWritable(stream).vbool();
		})),
		f("setBlocking", EvalEncode.vfun2((v1, v2) -> {
			var stream = decodeStream(v1);
			var block = EvalDecode.decodeBool(v2);
			encodeUnitResult(Uv.streamSetBlocking(stream, block));
		})),
	];

	// port: luv's `Stream.write_general`: the callback receives the bytes written.
	static function write(stream:Int, buffers:Array<LuvBuffer>, sendHandle:Int, callback:(Value, Int) -> Void):Void {
		var d = flatten(buffers);
		var bytes = d.data.length;
		var req = statusRequest(status -> {
			var bytesUnwritten = Uv.streamWriteQueueSize(stream);
			try callback(encodeUnitResult(status), bytes - bytesUnwritten)
			catch (e:Dynamic) unhandledException(e);
		});
		var r = Uv.streamWrite(stream, req, d.data, d.sizes, sendHandle);
		if (r < 0) {
			requestCallbacks.remove(req);
			Uv.reqFree(req);
			callback(error(r), 0);
		}
	}

	// port: ---- Signal
	public static final signumFields:Array<{name:String, value:Value}> = [
		f("SIGABRT", Uv.constant(5, 0).vint()),
		f("SIGFPE", Uv.constant(5, 1).vint()),
		f("SIGHUP", Uv.constant(5, 2).vint()),
		f("SIGILL", Uv.constant(5, 3).vint()),
		f("SIGINT", Uv.constant(5, 4).vint()),
		f("SIGKILL", Uv.constant(5, 5).vint()),
		f("SIGSEGV", Uv.constant(5, 6).vint()),
		f("SIGTERM", Uv.constant(5, 7).vint()),
		f("SIGWINCH", Uv.constant(5, 8).vint()),
	];

	public static final signalFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			encodeResult(Uv.handleInit(HK_SIGNAL, loop, 0, 0), s -> VHandle(HSignal(s)));
		})),
		f("start", EvalEncode.vfun3((v1, v2, v3) -> {
			var s = decodeSignal(v1);
			var signum = EvalDecode.decodeInt(v2);
			var cb = EvalMisc.prepareCallback(v3, 0);
			callbacks(s).cb = _ -> catchExceptions(_ -> cb([]), null);
			encodeUnitResult(Uv.signalStart(s, signum, false));
		})),
		f("startOneshot", EvalEncode.vfun3((v1, v2, v3) -> {
			var s = decodeSignal(v1);
			var signum = EvalDecode.decodeInt(v2);
			var cb = EvalMisc.prepareCallback(v3, 0);
			callbacks(s).cb = _ -> catchExceptions(_ -> cb([]), null);
			encodeUnitResult(Uv.signalStart(s, signum, true));
		})),
		f("stop", EvalEncode.vfun1(v -> {
			var s = decodeSignal(v);
			encodeUnitResult(Uv.signalStop(s));
		})),
		f("signum", EvalEncode.vfun1(v -> {
			var s = decodeSignal(v);
			Uv.signalSignum(s).vint();
		})),
	];

	// port: ---- Process
	public static final processFields:Array<{name:String, value:Value}> = [
		f("stdin", 0.vint()),
		f("stdout", 1.vint()),
		f("stderr", 2.vint()),
		f("toParentPipe", EvalEncode.vfun5((v1, v2, v3, v4, v5) -> {
			var fd = EvalDecode.decodeInt(v1);
			var parentPipe = decodePipe(v2);
			var readableInChild = EvalDecode.decodeBool(v3);
			var writableInChild = EvalDecode.decodeBool(v4);
			var overlapped = EvalDecode.decodeBool(v5);
			var flags = (readableInChild ? 1 : 0) | (writableInChild ? 2 : 0) | (overlapped ? 4 : 0);
			VHandle(HRedirection(new LuvRedirection(fd, 1, flags, parentPipe)));
		})),
		f("inheritFd", EvalEncode.vfun2((v1, v2) -> {
			var fd = EvalDecode.decodeInt(v1);
			var fromParentFd = EvalDecode.decodeInt(v2);
			VHandle(HRedirection(new LuvRedirection(fd, 2, 0, fromParentFd)));
		})),
		f("inheritStream", EvalEncode.vfun2((v1, v2) -> {
			var fd = EvalDecode.decodeInt(v1);
			var fromParentStream = decodeStream(v2);
			VHandle(HRedirection(new LuvRedirection(fd, 3, 0, fromParentStream)));
		})),
		f("spawn", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var loop = decodeLoop(v1);
			var cmd = EvalDecode.decodeNativeString(v2);
			var args = EvalDecode.decodeArray(v3).map(EvalDecode.decodeNativeString);
			var result = if (v4.match(VNull)) {
					spawn(loop, cmd, args, null, null, null, null, null, null, null, null, null, null, null);
				} else {
					var options = EvalDecode.decodeObject(v4);
					function get<T>(nameHash:Int, f:Value->T):Null<T> {
						var v = EvalField.objectField(options, nameHash);
						return EvalDecode.decodeOptional(f, v);
					}
					var onExit = get(EvalHash.key_onExit, v -> {
						var cb = EvalMisc.prepareCallback(v, 3);
						(p:Int, exitStatus:Int64, termSignal:Int) -> {
							cb([VHandle(HProcess(p)), VInt64(exitStatus), termSignal.vint()]);
						}
					});
					var environment = get(EvalHash.key_environment, v -> {
						switch EvalDecode.decodeInstance(v) {
							case {ikind: IStringMap(m)}:
								m.fold((k, e, acc:Array<{name:String, value:Bytes}>) -> {
									acc.unshift({name: k, value: EvalDecode.decodeNativeString(e.value)});
									acc;
								}, []);
							case _:
								EvalExceptions.unexpectedValue(v, "haxe.ds.Map<String,String>");
						}
					});
					var redirect = get(EvalHash.key_redirect, v -> {
						EvalDecode.decodeArray(v).map(v2 -> switch v2 {
							case VHandle(HRedirection(r)): (r : LuvRedirection);
							case _: EvalExceptions.unexpectedValue(v2, "eval.luv.Process.Redirection");
						});
					});
					var workingDirectory = get(EvalHash.key_workingDirectory, EvalDecode.decodeNativeString);
					var uid = get(EvalHash.key_uid, EvalDecode.decodeInt);
					var gid = get(EvalHash.key_gid, EvalDecode.decodeInt);
					var windowsVerbatimArguments = get(EvalHash.key_windowsVerbatimArguments, EvalDecode.decodeBool);
					var detached = get(EvalHash.key_detached, EvalDecode.decodeBool);
					var windowsHide = get(EvalHash.key_windowsHide, EvalDecode.decodeBool);
					var windowsHideConsole = get(EvalHash.key_windowsHideConsole, EvalDecode.decodeBool);
					var windowsHideGui = get(EvalHash.key_windowsHideGui, EvalDecode.decodeBool);
					// Process.spawn ~loop ?detached cmd args
					spawn(loop, cmd, args, onExit, environment, workingDirectory, redirect, uid, gid, windowsVerbatimArguments, detached,
						windowsHide, windowsHideConsole, windowsHideGui);
				}
			encodeResult(result, p -> VHandle(HProcess(p)));
		})),
		f("disableStdioInheritance", EvalEncode.vfun0(() -> {
			Uv.disableStdioInheritance();
			VNull;
		})),
		f("killPid", EvalEncode.vfun2((v1, v2) -> {
			var pid = EvalDecode.decodeInt(v1);
			var sigNum = EvalDecode.decodeInt(v2);
			encodeUnitResult(Uv.killPid(pid, sigNum));
		})),
		f("pid", EvalEncode.vfun1(v -> {
			var p = decodeProcess(v);
			Uv.processPid(p).vint();
		})),
	];

	// port: luv's `Process.spawn`.
	static function spawn(loop:Int, path:Bytes, arguments:Array<Bytes>, onExit:Null<(Int, Int64, Int) -> Void>,
			environment:Null<Array<{name:String, value:Bytes}>>, workingDirectory:Null<Bytes>, redirect:Null<Array<LuvRedirection>>,
			uid:Null<Int>, gid:Null<Int>, windowsVerbatimArguments:Null<Bool>, detached:Null<Bool>, windowsHide:Null<Bool>,
			windowsHideConsole:Null<Bool>, windowsHideGui:Null<Bool>):Int {
		var envHasEquals = environment != null && Lambda.exists(environment, e -> e.name.indexOf("=") >= 0);
		if (envHasEquals) return Uv.errCode(34); // port: EINVAL
		var env = environment == null ? null : environment.map(e -> {
			var b = new haxe.io.BytesBuffer();
			b.addString(e.name);
			b.addByte("=".code);
			b.addBytes(e.value, 0, e.value.length);
			b.getBytes();
		});
		var flags = 0;
		if (uid != null) flags |= 1;
		if (gid != null) flags |= 2;
		if (windowsVerbatimArguments == true) flags |= 4;
		if (detached == true) flags |= 8;
		if (windowsHide == true) flags |= 16;
		if (windowsHideConsole == true) flags |= 32;
		if (windowsHideGui == true) flags |= 64;
		var red = [];
		if (redirect != null) for (r in redirect) {
			red.push(r.fd);
			red.push(r.kind);
			red.push(r.flags);
			red.push(r.value);
		}
		var r = Uv.processSpawn(loop, path, arguments, env, workingDirectory, flags, uid == null ? 0 : uid, gid == null ? 0 : gid, red,
			onExit != null);
		if (r >= 0 && onExit != null) {
			var process = r;
			callbacks(process).exit = (exitStatus, termSignal) -> {
				try onExit(process, exitStatus, termSignal)
				catch (e:Dynamic) unhandledException(e);
			};
		}
		return r;
	}

	// port: ---- Request
	public static final requestFields:Array<{name:String, value:Value}> = [
		f("cancel", EvalEncode.vfun1(v -> {
			encodeUnitResult(switch v {
				case VHandle(HFileRequest(r)) | VHandle(HAddrRequest(r)) | VHandle(HNameRequest(r)) | VHandle(HRandomRequest(r)): Uv.reqCancel(r);
				case VHandle(HThreadPoolRequest(r)): return encodeIndexResult(LuvThreadPool.cancel(r));
				case _: EvalExceptions.unexpectedValue(v, "eval.luv.Request");
			});
		})),
	];

	// port: ---- Dns

	// port: A request of the user's, or a fresh one released after completion.
	static function orMake(request:Null<Int>):{req:Int, release:Bool} {
		return request == null ? {req: Uv.reqNew(), release: true} : {req: request, release: false};
	}

	public static final dnsFields:Array<{name:String, value:Value}> = [
		f("createAddrRequest", EvalEncode.vfun0(() -> {
			VHandle(HAddrRequest(Uv.reqNew()));
		})),
		f("createInfoRequest", EvalEncode.vfun0(() -> {
			VHandle(HNameRequest(Uv.reqNew()));
		})),
		f("getAddrInfo", EvalEncode.vfun5((v1, v2, v3, v4, v5) -> {
			var loop = decodeLoop(v1);
			var node = EvalDecode.decodeOptional(EvalDecode.decodeString, v2);
			var service = EvalDecode.decodeOptional(EvalDecode.decodeString, v3);
			if (node == null && service == null)
				EvalContext.throwValue(EvalMisc.createHaxeException("Either node or service has to be not null"), Globals.nullPos)
			else {
				var cb = EvalMisc.prepareCallback(v5, 1);
				var callback = (req:Int, status:Int) -> {
					var v = if (status < 0) error(status) else {
							var a = Uv.addrInfoResult(req);
							var infos = [];
							var i = 0;
							while (i < a.length) {
								var fields = [
									{name: EvalHash.key_family, value: encodeAddressFamily(a[i])},
									{name: EvalHash.key_sockType, value: encodeSocketType(a[i + 1])},
									{name: EvalHash.key_protocol, value: (a[i + 2] : Int).vint()},
									{name: EvalHash.key_addr, value: encodeSockaddr(a[i + 3])},
								];
								if (a[i
									+ 4] != null) fields.unshift({name: EvalHash.key_canonName, value: EvalString.createUnknown(a[i + 4])});
								infos.push(EvalEncode.encodeObj(fields));
								i += 5;
							}
							ok(EvalEncode.encodeArray(infos));
						}
					cb([v]);
				};
				var request:Null<Int> = null, family = -1, socktype = -1, protocol = -1, flags = -1, hasHints = false;
				if (!v4.match(VNull)) {
					var options = EvalDecode.decodeObject(v4);
					function get<T>(nameHash:Int, f:Value->T):Null<T> {
						var v = EvalField.objectField(options, nameHash);
						return EvalDecode.decodeOptional(f, v);
					}
					request = get(EvalHash.key_request, v -> switch v {
						case VHandle(HAddrRequest(r)): (r : Int);
						case v: EvalExceptions.unexpectedValue(v, "eval.luv.Dns.AddrInfoRequest");
					});
					var fa = get(EvalHash.key_family, decodeAddressFamily);
					var st = get(EvalHash.key_sockType, decodeSocketType);
					var pr = get(EvalHash.key_protocol, EvalDecode.decodeInt);
					var fl = get(EvalHash.key_flags, v -> {
						var r = 0;
						for (v in EvalDecode.decodeArray(v)) {
							var i = EvalDecode.decodeInt(v);
							if (i < 0 || i > 6) EvalExceptions.unexpectedValue(v, "eval.luv.Dns.AddrInfoFlag");
							r |= Uv.constant(6, i);
						}
						r;
					});
					// port: DNS.getaddrinfo: hints are passed when any of them is given
					hasHints = fa != null || st != null || pr != null || fl != null;
					if (fa != null) family = fa;
					if (st != null) socktype = st;
					if (pr != null) protocol = pr;
					if (fl != null) flags = fl;
				}
				var r = orMake(request);
				var req = r.req;
				requestCallbacks.set(req, status -> {
					try callback(req, status)
					catch (e:Dynamic) unhandledException(e);
					if (r.release) Uv.reqFree(req);
				});
				var res = Uv.getAddrInfo(loop, req, node, service, family, socktype, protocol, flags, hasHints);
				if (res < 0) {
					requestCallbacks.remove(req);
					if (r.release) Uv.reqFree(req);
					cb([error(res)]);
				}
			}
			VNull;
		})),
		f("getNameInfo", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var loop = decodeLoop(v1);
			var addr = decodeSockaddr(v2);
			var cb = EvalMisc.prepareCallback(v4, 1);
			var callback = (req:Int, status:Int) -> {
				var v = if (status < 0) error(status) else {
						var a = Uv.nameInfoResult(req);
						ok(EvalEncode.encodeObj([
							{name: EvalHash.key_node, value: EvalEncode.encodeString(a[0])},
							{name: EvalHash.key_service, value: EvalEncode.encodeString(a[1])}
						]));
					}
				cb([v]);
			};
			var request:Null<Int> = null, flags = 0;
			if (!v3.match(VNull)) {
				var options = EvalDecode.decodeObject(v3);
				function get<T>(nameHash:Int, f:Value->T):Null<T> {
					var v = EvalField.objectField(options, nameHash);
					return EvalDecode.decodeOptional(f, v);
				}
				request = get(EvalHash.key_request, v -> switch v {
					case VHandle(HNameRequest(r)): (r : Int);
					case v: EvalExceptions.unexpectedValue(v, "eval.luv.Dns.NameInfoRequest");
				});
				var fl = get(EvalHash.key_flags, v -> {
					var r = 0;
					for (v in EvalDecode.decodeArray(v)) {
						var i = EvalDecode.decodeInt(v);
						if (i < 0 || i > 4) EvalExceptions.unexpectedValue(v, "eval.luv.Dns.NameInfoFlag");
						r |= Uv.constant(7, i);
					}
					r;
				});
				if (fl != null) flags = fl;
			}
			var r = orMake(request);
			var req = r.req;
			requestCallbacks.set(req, status -> {
				try callback(req, status)
				catch (e:Dynamic) unhandledException(e);
				if (r.release) Uv.reqFree(req);
			});
			var res = Uv.getNameInfo(loop, req, addr, flags);
			if (res < 0) {
				requestCallbacks.remove(req);
				if (r.release) Uv.reqFree(req);
				cb([error(res)]);
			}
			VNull;
		})),
	];

	// port: ---- File (luv's file.ml: Async.async and Sync.sync over the host's uv_fs_* calls)
	static inline final FS_OPEN = 0;
	static inline final FS_CLOSE = 1;
	static inline final FS_READ = 2;
	static inline final FS_WRITE = 3;
	static inline final FS_UNLINK = 4;
	static inline final FS_MKDIR = 5;
	static inline final FS_MKDTEMP = 6;
	static inline final FS_MKSTEMP = 7;
	static inline final FS_RMDIR = 8;
	static inline final FS_OPENDIR = 9;
	static inline final FS_CLOSEDIR = 10;
	static inline final FS_READDIR = 11;
	static inline final FS_SCANDIR = 12;
	static inline final FS_STAT = 13;
	static inline final FS_LSTAT = 14;
	static inline final FS_FSTAT = 15;
	static inline final FS_STATFS = 16;
	static inline final FS_RENAME = 17;
	static inline final FS_FSYNC = 18;
	static inline final FS_FDATASYNC = 19;
	static inline final FS_FTRUNCATE = 20;
	static inline final FS_COPYFILE = 21;
	static inline final FS_SENDFILE = 22;
	static inline final FS_ACCESS = 23;
	static inline final FS_CHMOD = 24;
	static inline final FS_FCHMOD = 25;
	static inline final FS_UTIME = 26;
	static inline final FS_LUTIME = 27;
	static inline final FS_FUTIME = 28;
	static inline final FS_LINK = 29;
	static inline final FS_SYMLINK = 30;
	static inline final FS_READLINK = 31;
	static inline final FS_REALPATH = 32;
	static inline final FS_CHOWN = 33;
	static inline final FS_LCHOWN = 34;
	static inline final FS_FCHOWN = 35;

	// port: luv's `Returns`: the result of a completed request, and whether success cleans it up.
	static function returnsError(req:Int):Value return encodeUnitResult(Uv.fsResult(req));

	static function returnsFile(req:Int):Value return encodeResult(Uv.fsResult(req), fd -> VHandle(HFile(fd)));

	static function returnsByteCount(req:Int):Value return encodeResult(Uv.fsResult(req), n -> EvalIntegers.encodeSizeT(Int64.ofInt(n)));

	static function returnsPath(req:Int):Value return encodeResult(Uv.fsResult(req), _ -> Uv.fsPath(req).vnativeString());

	static function returnsPathAndFile(req:Int):Value {
		return encodeResult(Uv.fsResult(req), file -> EvalEncode.encodeObj([
			{name: EvalHash.key_name, value: Uv.fsPath(req).vnativeString()},
			{name: EvalHash.key_file, value: VHandle(HFile(file))}
		]));
	}

	static function returnsDirectoryHandle(req:Int):Value return encodeResult(Uv.fsResult(req), _ -> VHandle(HDir(Uv.fsDir(req))));

	static function returnsDirectoryEntries(req:Int):Value {
		return encodeResult(Uv.fsResult(req), _ -> {
			var a = Uv.fsDirents(req);
			EvalEncode.encodeArrayA([for (i in 0...a.length >> 1) encodeDirent(a[2 * i], a[2 * i + 1])]);
		});
	}

	static function returnsStat(req:Int):Value {
		return encodeResult(Uv.fsResult(req), _ -> {
			var b = Bytes.alloc(160);
			Uv.fsStat(req, b);
			encodeFileStat(b);
		});
	}

	static function returnsStatfs(req:Int):Value {
		return encodeResult(Uv.fsResult(req), _ -> {
			var b = Bytes.alloc(88);
			Uv.fsStatfs(req, b);
			encodeFileStatfs(b);
		});
	}

	static function returnsString(req:Int):Value return encodeResult(Uv.fsResult(req), _ -> Uv.fsPtrString(req).vnativeString());

	// port: one luv File function. `vloop` VNull: `File.Sync` (the result is returned);
	// otherwise `File.Async` (the result goes to `vcallback`). `cleanupOnSuccess`:
	// `clean_up_request_on_success` (false for scandir). `after` runs where luv's
	// `cleanup` does (reads copy their data out there).
	static function fsCall(sync:Bool, vloop:Value, vrequest:Value, vcallback:Value, op:Int, p1:Null<Bytes>, p2:Null<Bytes>, i1:Int,
			i2:Int, i3:Int, f1:Float, f2:Float, buffers:Null<Array<LuvBuffer>>, returns:Int->Value, cleanupOnSuccess:Bool = true):Value {
		var write = op == FS_WRITE;
		var d = buffers == null ? null : write ? flatten(buffers) : {data: null, sizes: [for (b in buffers) b.length]};
		function cleanup(req:Int):Void {
			if (op == FS_READ) {
				var n = Uv.fsResult(req);
				if (n > 0) copyOut(req, buffers, n);
			}
		}
		if (sync) {
			// port: Sync.sync
			var req = Uv.reqNew();
			var immediateResult = Uv.fs(op, -1, req, p1, p2, i1, i2, i3, f1, f2, d == null ? null : d.data, d == null ? null : d.sizes);
			cleanup(req);
			var result = if (immediateResult < 0) error(immediateResult) else returns(req);
			if (cleanupOnSuccess || immediateResult < 0) Uv.fsCleanup(req);
			// port: a scan keeps its request until scandir_end
			if (cleanupOnSuccess || immediateResult < 0) Uv.reqFree(req);
			return result;
		}
		// port: Async.async
		var loop = decodeLoop(vloop);
		var request = EvalDecode.decodeOptional(decodeFileRequest, vrequest);
		var callback = encodeCallback(vcallback);
		var release = request == null;
		var req = request == null ? Uv.reqNew() : request;
		requestCallbacks.set(req, _ -> {
			var result = returns(req);
			var failed = Uv.fsResult(req) < 0;
			if (cleanupOnSuccess || failed) Uv.fsCleanup(req);
			cleanup(req);
			catchExceptions(callback, result);
			if (release && (cleanupOnSuccess || failed)) Uv.reqFree(req);
		});
		var immediateResult = Uv.fs(op, loop, req, p1, p2, i1, i2, i3, f1, f2, d == null ? null : d.data, d == null ? null : d.sizes);
		if (immediateResult < 0) {
			requestCallbacks.remove(req);
			Uv.fsCleanup(req);
			if (release) Uv.reqFree(req);
			callback(error(immediateResult));
		}
		return VNull;
	}

	static function path(v:Value):Bytes return EvalDecode.decodeNativeString(v);

	static function openFlags(v:Value):Int {
		var r = 0;
		for (fl in EvalDecode.decodeArray(v).map(decodeFileOpenFlag)) r |= fl;
		return r;
	}

	// port: `F.mode_opt`: the default mode when none is given.
	static function modeOpt(v:Value, def:Int):Int {
		var mode = EvalDecode.decodeOptional(decodeFileModeList, v);
		return mode == null ? def : mode;
	}

	static function copyFlags(v:Value):Int {
		var flags = decodeIntFlags(v);
		return (flags.contains(0) ? Uv.constant(8,
			0) : 0) | (flags.contains(1) ? Uv.constant(8, 1) : 0) | (flags.contains(2) ? Uv.constant(8, 2) : 0);
	}

	static function symlinkFlags(v:Value):Int {
		var flags = decodeIntFlags(v);
		return (flags.contains(0) ? Uv.constant(8, 3) : 0) | (flags.contains(1) ? Uv.constant(8, 4) : 0);
	}

	static function accessFlags(v:Value):Int {
		var r = 0;
		for (v in EvalDecode.decodeArray(v)) {
			var i = EvalDecode.decodeInt(v);
			if (i < 0 || i > 3) EvalExceptions.unexpectedValue(v, "eval.luv.File.FileAccessFlag");
			r |= Uv.constant(2, i);
		}
		return r;
	}

	static function i64Float(v:Value):Float return EvalIntegers.decodeI64(v).toFloat();

	public static final fileFields:Array<{name:String, value:Value}> = [
		f("stdin", VHandle(HFile(0))),
		f("stdout", VHandle(HFile(1))),
		f("stderr", VHandle(HFile(2))),
		f("createRequest", EvalEncode.vfun0(() -> {
			VHandle(HFileRequest(Uv.reqNew()));
		})),
		f("testMode", EvalEncode.vfun2((v1, v2) -> {
			var mask = decodeFileModeList(v1);
			var bits = switch v2 {
					case VHandle(HFileModeNumeric(m)): (m : Int);
					case _: EvalExceptions.unexpectedValue(v2, "eval.luv.File.FileModeNumeric");
				}
				(mask & bits == mask).vbool();
		})),
		f("open", EvalEncode.vfun6((vloop, vpath, vflags, vmode, vrequest, vcallback) -> {
			var flags = openFlags(vflags);
			var mode = modeOpt(vmode, 420); // port: Mode.file_default: 0o644
			fsCall(false, vloop, vrequest, vcallback, FS_OPEN, path(vpath), null, flags, mode, 0, 0, 0, null, returnsFile);
		})),
		f("close", EvalEncode.vfun4((vfile, vloop, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_CLOSE, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsError);
		})),
		f("read", EvalEncode.vfun6((vfile, vloop, vfileOffset, vbuffers, vrequest, vcallback) -> {
			var file = decodeFile(vfile);
			var fileOffset = i64Float(vfileOffset);
			var buffers = decodeBuffers(vbuffers);
			fsCall(false, vloop, vrequest, vcallback, FS_READ, null, null, file, 0, 0, fileOffset, 0, buffers, returnsByteCount);
		})),
		f("write", EvalEncode.vfun6((vfile, vloop, vfileOffset, vbuffers, vrequest, vcallback) -> {
			var file = decodeFile(vfile);
			var fileOffset = i64Float(vfileOffset);
			var buffers = decodeBuffers(vbuffers);
			fsCall(false, vloop, vrequest, vcallback, FS_WRITE, null, null, file, 0, 0, fileOffset, 0, buffers, returnsByteCount);
		})),
		f("unlink", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_UNLINK, path(vpath), null, 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("rename", EvalEncode.vfun5((vloop, vpath, vto, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_RENAME, path(vpath), path(vto), 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("mkstemp", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_MKSTEMP, path(vpath), null, 0, 0, 0, 0, 0, null, returnsPathAndFile);
		})),
		f("mkdtemp", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_MKDTEMP, path(vpath), null, 0, 0, 0, 0, 0, null, returnsPath);
		})),
		f("mkdir", EvalEncode.vfun5((vloop, vpath, vmode, vrequest, vcallback) -> {
			var mode = modeOpt(vmode, 493); // port: Mode.directory_default: 0o755
			fsCall(false, vloop, vrequest, vcallback, FS_MKDIR, path(vpath), null, mode, 0, 0, 0, 0, null, returnsError);
		})),
		f("rmdir", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_RMDIR, path(vpath), null, 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("stat", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_STAT, path(vpath), null, 0, 0, 0, 0, 0, null, returnsStat);
		})),
		f("lstat", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_LSTAT, path(vpath), null, 0, 0, 0, 0, 0, null, returnsStat);
		})),
		f("fstat", EvalEncode.vfun4((vfile, vloop, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_FSTAT, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsStat);
		})),
		f("statFs", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_STATFS, path(vpath), null, 0, 0, 0, 0, 0, null, returnsStatfs);
		})),
		f("fsync", EvalEncode.vfun4((vfile, vloop, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_FSYNC, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsError);
		})),
		f("fdataSync", EvalEncode.vfun4((vfile, vloop, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_FDATASYNC, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsError);
		})),
		f("ftruncate", EvalEncode.vfun5((vfile, vloop, vlength, vrequest, vcallback) -> {
			var file = decodeFile(vfile);
			var length = i64Float(vlength);
			fsCall(false, vloop, vrequest, vcallback, FS_FTRUNCATE, null, null, file, 0, 0, length, 0, null, returnsError);
		})),
		f("copyFile", EvalEncode.vfun6((vloop, vpath, vto, vflags, vrequest, vcallback) -> {
			var flags = copyFlags(vflags);
			fsCall(false, vloop, vrequest, vcallback, FS_COPYFILE, path(vpath), path(vto), flags, 0, 0, 0, 0, null, returnsError);
		})),
		f("sendFile", EvalEncode.vfun7((vfile, vloop, vto, voffset, vlength, vrequest, vcallback) -> {
			var to = decodeFile(vto);
			var offset = i64Float(voffset);
			var length = EvalIntegers.decodeSizeT(vlength).toFloat();
			var file = decodeFile(vfile);
			fsCall(false, vloop, vrequest, vcallback, FS_SENDFILE, null, null, file, to, 0, offset, length, null, returnsByteCount);
		})),
		f("access", EvalEncode.vfun5((vloop, vpath, vflags, vrequest, vcallback) -> {
			var flags = accessFlags(vflags);
			fsCall(false, vloop, vrequest, vcallback, FS_ACCESS, path(vpath), null, flags, 0, 0, 0, 0, null, returnsError);
		})),
		f("chmod", EvalEncode.vfun5((vloop, vpath, vmode, vrequest, vcallback) -> {
			var p = path(vpath);
			var mode = decodeFileModeList(vmode);
			fsCall(false, vloop, vrequest, vcallback, FS_CHMOD, p, null, mode, 0, 0, 0, 0, null, returnsError);
		})),
		f("fchmod", EvalEncode.vfun5((vfile, vloop, vmode, vrequest, vcallback) -> {
			var file = decodeFile(vfile);
			var mode = decodeFileModeList(vmode);
			fsCall(false, vloop, vrequest, vcallback, FS_FCHMOD, null, null, file, mode, 0, 0, 0, null, returnsError);
		})),
		f("utime", EvalEncode.vfun6((vloop, vpath, vatime, vmtime, vrequest, vcallback) -> {
			var p = path(vpath);
			var atime = EvalDecode.num(vatime);
			var mtime = EvalDecode.num(vmtime);
			fsCall(false, vloop, vrequest, vcallback, FS_UTIME, p, null, 0, 0, 0, atime, mtime, null, returnsError);
		})),
		f("lutime", EvalEncode.vfun6((vloop, vpath, vatime, vmtime, vrequest, vcallback) -> {
			var p = path(vpath);
			var atime = EvalDecode.num(vatime);
			var mtime = EvalDecode.num(vmtime);
			fsCall(false, vloop, vrequest, vcallback, FS_LUTIME, p, null, 0, 0, 0, atime, mtime, null, returnsError);
		})),
		f("futime", EvalEncode.vfun6((vfile, vloop, vatime, vmtime, vrequest, vcallback) -> {
			var file = decodeFile(vfile);
			var atime = EvalDecode.num(vatime);
			var mtime = EvalDecode.num(vmtime);
			fsCall(false, vloop, vrequest, vcallback, FS_FUTIME, null, null, file, 0, 0, atime, mtime, null, returnsError);
		})),
		f("link", EvalEncode.vfun5((vloop, vpath, vlink, vrequest, vcallback) -> {
			var p = path(vpath);
			var link = path(vlink);
			fsCall(false, vloop, vrequest, vcallback, FS_LINK, p, link, 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("symlink", EvalEncode.vfun6((vloop, vpath, vlink, vflags, vrequest, vcallback) -> {
			var flags = symlinkFlags(vflags);
			var p = path(vpath);
			var link = path(vlink);
			fsCall(false, vloop, vrequest, vcallback, FS_SYMLINK, p, link, flags, 0, 0, 0, 0, null, returnsError);
		})),
		f("readLink", EvalEncode.vfun4((vloop, vpath, vrequest, v4) -> {
			fsCall(false, vloop, vrequest, v4, FS_READLINK, path(vpath), null, 0, 0, 0, 0, 0, null, returnsString);
		})),
		f("realPath", EvalEncode.vfun4((vloop, vpath, vrequest, v4) -> {
			fsCall(false, vloop, vrequest, v4, FS_REALPATH, path(vpath), null, 0, 0, 0, 0, 0, null, returnsString);
		})),
		f("chown", EvalEncode.vfun6((vloop, vpath, vuid, vgid, vrequest, vcallback) -> {
			var p = path(vpath);
			var uid = EvalDecode.decodeInt(vuid);
			var gid = EvalDecode.decodeInt(vgid);
			fsCall(false, vloop, vrequest, vcallback, FS_CHOWN, p, null, uid, gid, 0, 0, 0, null, returnsError);
		})),
		f("lchown", EvalEncode.vfun6((vloop, vpath, vuid, vgid, vrequest, vcallback) -> {
			var p = path(vpath);
			var uid = EvalDecode.decodeInt(vuid);
			var gid = EvalDecode.decodeInt(vgid);
			fsCall(false, vloop, vrequest, vcallback, FS_LCHOWN, p, null, uid, gid, 0, 0, 0, null, returnsError);
		})),
		f("fchown", EvalEncode.vfun6((vfile, vloop, vuid, vgid, vrequest, vcallback) -> {
			var file = decodeFile(vfile);
			var uid = EvalDecode.decodeInt(vuid);
			var gid = EvalDecode.decodeInt(vgid);
			fsCall(false, vloop, vrequest, vcallback, FS_FCHOWN, null, null, 0, file, uid, gid, 0, null, returnsError);
		})),
		f("toInt", EvalEncode.vfun1(v -> {
			var file = decodeFile(v);
			file.vint();
		})),
	];

	public static final fileSyncFields:Array<{name:String, value:Value}> = [
		f("open", EvalEncode.vfun3((vpath, vflags, vmode) -> {
			var flags = openFlags(vflags);
			var mode = modeOpt(vmode, 420);
			fsCall(true, VNull, VNull, VNull, FS_OPEN, path(vpath), null, flags, mode, 0, 0, 0, null, returnsFile);
		})),
		f("close", EvalEncode.vfun1(vfile -> {
			fsCall(true, VNull, VNull, VNull, FS_CLOSE, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsError);
		})),
		f("read", EvalEncode.vfun3((vfile, vfileOffset, vbuffers) -> {
			var file = decodeFile(vfile);
			var fileOffset = i64Float(vfileOffset);
			var buffers = decodeBuffers(vbuffers);
			fsCall(true, VNull, VNull, VNull, FS_READ, null, null, file, 0, 0, fileOffset, 0, buffers, returnsByteCount);
		})),
		f("write", EvalEncode.vfun3((vfile, vfileOffset, vbuffers) -> {
			var file = decodeFile(vfile);
			var fileOffset = i64Float(vfileOffset);
			var buffers = decodeBuffers(vbuffers);
			fsCall(true, VNull, VNull, VNull, FS_WRITE, null, null, file, 0, 0, fileOffset, 0, buffers, returnsByteCount);
		})),
		f("unlink", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_UNLINK, path(vpath), null, 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("rename", EvalEncode.vfun2((vpath, vto) -> {
			fsCall(true, VNull, VNull, VNull, FS_RENAME, path(vpath), path(vto), 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("mkstemp", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_MKSTEMP, path(vpath), null, 0, 0, 0, 0, 0, null, returnsPathAndFile);
		})),
		f("mkdtemp", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_MKDTEMP, path(vpath), null, 0, 0, 0, 0, 0, null, returnsPath);
		})),
		f("mkdir", EvalEncode.vfun2((vpath, vmode) -> {
			var mode = modeOpt(vmode, 493);
			fsCall(true, VNull, VNull, VNull, FS_MKDIR, path(vpath), null, mode, 0, 0, 0, 0, null, returnsError);
		})),
		f("rmdir", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_RMDIR, path(vpath), null, 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("stat", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_STAT, path(vpath), null, 0, 0, 0, 0, 0, null, returnsStat);
		})),
		f("lstat", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_LSTAT, path(vpath), null, 0, 0, 0, 0, 0, null, returnsStat);
		})),
		f("fstat", EvalEncode.vfun1(vfile -> {
			fsCall(true, VNull, VNull, VNull, FS_FSTAT, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsStat);
		})),
		f("statFs", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_STATFS, path(vpath), null, 0, 0, 0, 0, 0, null, returnsStatfs);
		})),
		f("fsync", EvalEncode.vfun1(vfile -> {
			fsCall(true, VNull, VNull, VNull, FS_FSYNC, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsError);
		})),
		f("fdataSync", EvalEncode.vfun1(vfile -> {
			fsCall(true, VNull, VNull, VNull, FS_FDATASYNC, null, null, decodeFile(vfile), 0, 0, 0, 0, null, returnsError);
		})),
		f("ftruncate", EvalEncode.vfun2((vfile, vlength) -> {
			var file = decodeFile(vfile);
			var length = i64Float(vlength);
			fsCall(true, VNull, VNull, VNull, FS_FTRUNCATE, null, null, file, 0, 0, length, 0, null, returnsError);
		})),
		f("copyFile", EvalEncode.vfun3((vpath, vto, vflags) -> {
			var flags = copyFlags(vflags);
			fsCall(true, VNull, VNull, VNull, FS_COPYFILE, path(vpath), path(vto), flags, 0, 0, 0, 0, null, returnsError);
		})),
		f("sendFile", EvalEncode.vfun4((vfile, vto, voffset, vlength) -> {
			var to = decodeFile(vto);
			var offset = i64Float(voffset);
			var length = EvalIntegers.decodeSizeT(vlength).toFloat();
			var file = decodeFile(vfile);
			fsCall(true, VNull, VNull, VNull, FS_SENDFILE, null, null, file, to, 0, offset, length, null, returnsByteCount);
		})),
		f("access", EvalEncode.vfun2((vpath, vflags) -> {
			var flags = accessFlags(vflags);
			fsCall(true, VNull, VNull, VNull, FS_ACCESS, path(vpath), null, flags, 0, 0, 0, 0, null, returnsError);
		})),
		f("chmod", EvalEncode.vfun2((vpath, vmode) -> {
			var p = path(vpath);
			var mode = decodeFileModeList(vmode);
			fsCall(true, VNull, VNull, VNull, FS_CHMOD, p, null, mode, 0, 0, 0, 0, null, returnsError);
		})),
		f("fchmod", EvalEncode.vfun2((vfile, vmode) -> {
			var file = decodeFile(vfile);
			var mode = decodeFileModeList(vmode);
			fsCall(true, VNull, VNull, VNull, FS_FCHMOD, null, null, file, mode, 0, 0, 0, null, returnsError);
		})),
		f("utime", EvalEncode.vfun3((vpath, vatime, vmtime) -> {
			var p = path(vpath);
			var atime = EvalDecode.num(vatime);
			var mtime = EvalDecode.num(vmtime);
			fsCall(true, VNull, VNull, VNull, FS_UTIME, p, null, 0, 0, 0, atime, mtime, null, returnsError);
		})),
		f("lutime", EvalEncode.vfun3((vpath, vatime, vmtime) -> {
			var p = path(vpath);
			var atime = EvalDecode.num(vatime);
			var mtime = EvalDecode.num(vmtime);
			fsCall(true, VNull, VNull, VNull, FS_LUTIME, p, null, 0, 0, 0, atime, mtime, null, returnsError);
		})),
		f("futime", EvalEncode.vfun3((vfile, vatime, vmtime) -> {
			var file = decodeFile(vfile);
			var atime = EvalDecode.num(vatime);
			var mtime = EvalDecode.num(vmtime);
			fsCall(true, VNull, VNull, VNull, FS_FUTIME, null, null, file, 0, 0, atime, mtime, null, returnsError);
		})),
		f("link", EvalEncode.vfun2((vpath, vlink) -> {
			var p = path(vpath);
			var link = path(vlink);
			fsCall(true, VNull, VNull, VNull, FS_LINK, p, link, 0, 0, 0, 0, 0, null, returnsError);
		})),
		f("symlink", EvalEncode.vfun3((vpath, vlink, vflags) -> {
			var flags = symlinkFlags(vflags);
			var p = path(vpath);
			var link = path(vlink);
			fsCall(true, VNull, VNull, VNull, FS_SYMLINK, p, link, flags, 0, 0, 0, 0, null, returnsError);
		})),
		f("readLink", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_READLINK, path(vpath), null, 0, 0, 0, 0, 0, null, returnsString);
		})),
		f("realPath", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_REALPATH, path(vpath), null, 0, 0, 0, 0, 0, null, returnsString);
		})),
		f("chown", EvalEncode.vfun3((vpath, vuid, vgid) -> {
			var p = path(vpath);
			var uid = EvalDecode.decodeInt(vuid);
			var gid = EvalDecode.decodeInt(vgid);
			fsCall(true, VNull, VNull, VNull, FS_CHOWN, p, null, uid, gid, 0, 0, 0, null, returnsError);
		})),
		f("lchown", EvalEncode.vfun3((vpath, vuid, vgid) -> {
			var p = path(vpath);
			var uid = EvalDecode.decodeInt(vuid);
			var gid = EvalDecode.decodeInt(vgid);
			fsCall(true, VNull, VNull, VNull, FS_LCHOWN, p, null, uid, gid, 0, 0, 0, null, returnsError);
		})),
		f("fchown", EvalEncode.vfun3((vfile, vuid, vgid) -> {
			var file = decodeFile(vfile);
			var uid = EvalDecode.decodeInt(vuid);
			var gid = EvalDecode.decodeInt(vgid);
			fsCall(true, VNull, VNull, VNull, FS_FCHOWN, null, null, 0, file, uid, gid, 0, null, returnsError);
		})),
	];

	// port: ---- Dir

	static function readdirEntries(v:Value):Int {
		var numberOfEntries = EvalDecode.decodeOptional(EvalDecode.decodeInt, v);
		return numberOfEntries == null ? 1024 : numberOfEntries;
	}

	public static final dirFields:Array<{name:String, value:Value}> = [
		f("open", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_OPENDIR, path(vpath), null, 0, 0, 0, 0, 0, null, returnsDirectoryHandle);
		})),
		f("close", EvalEncode.vfun4((vdir, vloop, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_CLOSEDIR, null, null, decodeDir(vdir), 0, 0, 0, 0, null, returnsError);
		})),
		f("read", EvalEncode.vfun5((vdir, vloop, vnumberOfEntries, vrequest, vcallback) -> {
			var n = readdirEntries(vnumberOfEntries);
			var dir = decodeDir(vdir);
			fsCall(false, vloop, vrequest, vcallback, FS_READDIR, null, null, dir, n, 0, 0, 0, null, returnsDirectoryEntries);
		})),
		f("scan", EvalEncode.vfun4((vloop, vpath, vrequest, vcallback) -> {
			fsCall(false, vloop, vrequest, vcallback, FS_SCANDIR, path(vpath), null, 0, 0, 0, 0, 0, null,
				req -> encodeResult(Uv.fsResult(req), _ -> encodeScandir(req)), false);
		})),
	];

	public static final dirSyncFields:Array<{name:String, value:Value}> = [
		f("open", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_OPENDIR, path(vpath), null, 0, 0, 0, 0, 0, null, returnsDirectoryHandle);
		})),
		f("close", EvalEncode.vfun1(vdir -> {
			fsCall(true, VNull, VNull, VNull, FS_CLOSEDIR, null, null, decodeDir(vdir), 0, 0, 0, 0, null, returnsError);
		})),
		f("read", EvalEncode.vfun2((vdir, vnumberOfEntries) -> {
			var n = readdirEntries(vnumberOfEntries);
			var dir = decodeDir(vdir);
			fsCall(true, VNull, VNull, VNull, FS_READDIR, null, null, dir, n, 0, 0, 0, null, returnsDirectoryEntries);
		})),
		f("scan", EvalEncode.vfun1(vpath -> {
			fsCall(true, VNull, VNull, VNull, FS_SCANDIR, path(vpath), null, 0, 0, 0, 0, 0, null,
				req -> encodeResult(Uv.fsResult(req), _ -> encodeScandir(req)), false);
		})),
	];

	// port: ---- FsEvent
	public static final fsEventFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			encodeResult(Uv.handleInit(HK_FS_EVENT, loop, 0, 0), e -> VHandle(HFsEvent(e)));
		})),
		f("start", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var event = decodeFsEvent(v1);
			var path = EvalDecode.decodeNativeString(v2);
			var callback = encodeCallback(v4);
			var flags = if (v3.match(VNull)) 0 else {
					var flags = decodeIntFlags(v3);
					(flags.contains(0) ? Uv.constant(12,
						2) : 0) | (flags.contains(1) ? Uv.constant(12, 3) : 0) | (flags.contains(2) ? Uv.constant(12, 4) : 0);
				}
			// port: FS_event.start
			callbacks(event).data = (status, b) -> {
				var result = if (status < 0) error(status) else {
						var a:Array<Dynamic> = b;
						var events:Int = a[1];
						var vevents = [];
						if (events & Uv.constant(12, 0) != 0) vevents.push(0.vint()); // port: RENAME
						if (events & Uv.constant(12, 1) != 0) vevents.push(1.vint()); // port: CHANGE
						ok(EvalEncode.encodeObj([
							{name: EvalHash.key_file, value: EvalEncode.encodeNullable(EvalValueTools.vnativeString, (a[0] : Null<Bytes>))},
							{name: EvalHash.key_events, value: EvalEncode.encodeArray(vevents)}
						]));
					}
				catchExceptions(callback, result);
			};
			var r = Uv.fsEventStart(event, path, flags);
			if (r < 0) callback(error(r));
			VNull;
		})),
		f("stop", EvalEncode.vfun1(v -> {
			var event = decodeFsEvent(v);
			encodeUnitResult(Uv.fsEventStop(event));
		})),
	];

	// port: ---- threads and synchronization (see the module comment)

	// port: A `Result.Error` of a luv `Error.t` index (the primitives below report indices, not libuv codes).
	static function errorIndex(i:Int):Value return EvalEncode.encodeEnumValue(EvalHash.key_eval_luv_Result, 1, vector(i.vint()), null);

	static function encodeIndexResult(i:Int):Value return i == 0 ? ok(VNull) : errorIndex(i);

	static function prepareLuvCallback(v:Value):Void->Void {
		return switch v {
			case VFunction(_) | VFieldClosure(_):
				() -> {
					var ctx = EvalContext.getCtx();
					switch EvalContext.getEvalOpt(ctx) {
						case null:
							var thread = EvalThread.createThreadInfo(ctx, LuvThread(LuvThreadHandle.self()));
							var eval = EvalThread.createEval(thread);
							EvalContext.setEval(ctx, eval);
						case _:
					}
					EvalExceptions.catchExceptions(ctx, () -> EvalMisc.callValue(v, []), Globals.nullPos);
				}
			case _:
				throw macros.MacroApi.InvalidExpr.raise();
		}
	}

	public static final threadPoolFields:Array<{name:String, value:Value}> = [
		f("createRequest", EvalEncode.vfun0(() -> {
			VHandle(HThreadPoolRequest(new LuvWorkRequest()));
		})),
		f("queueWork", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var loop = decodeLoop(v1);
			var request = EvalDecode.decodeOptional(v -> switch v {
				case VHandle(HThreadPoolRequest(r)): (r : LuvWorkRequest);
				case v: EvalExceptions.unexpectedValue(v, "eval.luv.ThreadPool.ThreadPoolRequest");
			}, v2);
			var work = prepareLuvCallback(v3);
			var callback = encodeCallback(v4);
			// port: Thread_pool.queue_work: the work runs on a pool thread, then the callback on the
			// loop, reached through an async handle the pool signals (see LuvThreadPool)
			var request = request == null ? new LuvWorkRequest() : request;
			var r = Uv.handleInit(HK_ASYNC, loop, 0, 0);
			if (r < 0) {
				catchExceptions(callback, error(r));
			} else {
				var async = r;
				var status = 0;
				callbacks(async).cb = _ -> {
					Uv.handleClose(async);
					catchExceptions(callback, encodeIndexResult(status));
				};
				request.work = () -> catchExceptions(_ -> work(), null);
				request.done = s -> {
					status = s;
					Uv.asyncSend(async);
				};
				LuvThreadPool.queueWork(request);
			}
			VNull;
		})),
		f("setSize", EvalEncode.vfun2((v1, v2) -> {
			var size = EvalDecode.decodeInt(v1);
			var ifNotAlreadySet = EvalDecode.decodeOptional(EvalDecode.decodeBool, v2);
			// port: luv's Thread_pool.set_size: sets UV_THREADPOOL_SIZE, read when a pool starts
			if (!(ifNotAlreadySet == true && Sys.getEnv("UV_THREADPOOL_SIZE") != null))
				Sys.putEnv("UV_THREADPOOL_SIZE", Std.string(size));
			VNull;
		})),
	];

	public static final threadFields:Array<{name:String, value:Value}> = [
		f("self", EvalEncode.vfun0(() -> {
			VHandle(HThread(LuvThreadHandle.self()));
		})),
		f("create", EvalEncode.vfun2((v1, v2) -> {
			var fn = prepareLuvCallback(v1);
			// port: ignored: host threads have a fixed stack size
			var stackSize = EvalDecode.decodeOptional(EvalDecode.decodeInt, v2);
			// port: luv's Thread.create runs the function under Error.catch_exceptions
			ok(VHandle(HThread(LuvThreadHandle.create(() -> catchExceptions(_ -> fn(), null)))));
		})),
		f("join", EvalEncode.vfun1(v -> {
			var thread = switch v {
					case VHandle(HThread(t)): (t : LuvThreadHandle);
					case _: EvalExceptions.unexpectedValue(v, "eval.luv.Thread");
				}
			encodeIndexResult(EvalLock.blocking(() -> thread.join()));
		})),
	];

	public static final onceFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun0(() -> {
			ok(VHandle(HOnce(new LuvOnce())));
		})),
		f("once", EvalEncode.vfun2((v1, v2) -> {
			var once = switch v1 {
					case VHandle(HOnce(o)): (o : LuvOnce);
					case _: EvalExceptions.unexpectedValue(v1, "eval.luv.Once");
				}
			var callback = EvalMisc.prepareCallback(v2, 0);
			once.once(() -> callback([]));
			VNull;
		})),
	];

	public static final mutexFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			var recursive = EvalDecode.decodeOptional(EvalDecode.decodeBool, v);
			ok(VHandle(HMutex(new LuvMutex(recursive == true))));
		})),
		f("destroy", EvalEncode.vfun1(v -> {
			decodeMutex(v);
			VNull;
		})),
		f("lock", EvalEncode.vfun1(v -> {
			decodeMutex(v).lock();
			VNull;
		})),
		f("tryLock", EvalEncode.vfun1(v -> {
			encodeIndexResult(decodeMutex(v).tryLock());
		})),
		f("unlock", EvalEncode.vfun1(v -> {
			decodeMutex(v).unlock();
			VNull;
		})),
	];

	public static final rwlockFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun0(() -> {
			ok(VHandle(HRwLock(new LuvRwLock())));
		})),
		f("destroy", EvalEncode.vfun1(v -> {
			decodeRwlock(v);
			VNull;
		})),
		f("rdLock", EvalEncode.vfun1(v -> {
			decodeRwlock(v).rdLock();
			VNull;
		})),
		f("rdTryLock", EvalEncode.vfun1(v -> {
			encodeIndexResult(decodeRwlock(v).rdTryLock());
		})),
		f("rdUnlock", EvalEncode.vfun1(v -> {
			decodeRwlock(v).rdUnlock();
			VNull;
		})),
		f("wrLock", EvalEncode.vfun1(v -> {
			decodeRwlock(v).wrLock();
			VNull;
		})),
		f("wrTryLock", EvalEncode.vfun1(v -> {
			encodeIndexResult(decodeRwlock(v).wrTryLock());
		})),
		f("wrUnlock", EvalEncode.vfun1(v -> {
			decodeRwlock(v).wrUnlock();
			VNull;
		})),
	];

	public static final semaphoreFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			ok(VHandle(HSemaphore(new LuvSemaphore(EvalDecode.decodeInt(v)))));
		})),
		f("destroy", EvalEncode.vfun1(v -> {
			decodeSemaphore(v);
			VNull;
		})),
		f("post", EvalEncode.vfun1(v -> {
			decodeSemaphore(v).post();
			VNull;
		})),
		f("wait", EvalEncode.vfun1(v -> {
			decodeSemaphore(v).wait();
			VNull;
		})),
		f("tryWait", EvalEncode.vfun1(v -> {
			encodeIndexResult(decodeSemaphore(v).tryWait());
		})),
	];

	public static final conditionFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun0(() -> {
			ok(VHandle(HCondition(new LuvCondition())));
		})),
		f("destroy", EvalEncode.vfun1(v -> {
			decodeCondition(v);
			VNull;
		})),
		f("signal", EvalEncode.vfun1(v -> {
			decodeCondition(v).signal();
			VNull;
		})),
		f("broadcast", EvalEncode.vfun1(v -> {
			decodeCondition(v).broadcast();
			VNull;
		})),
		f("wait", EvalEncode.vfun2((v1, v2) -> {
			var condition = decodeCondition(v1);
			var mutex = decodeMutex(v2);
			condition.wait(mutex);
			VNull;
		})),
		f("timedWait", EvalEncode.vfun3((v1, v2, v3) -> {
			var condition = decodeCondition(v1);
			var mutex = decodeMutex(v2);
			var timeout = EvalDecode.decodeInt(v3);
			encodeIndexResult(condition.timedWait(mutex, timeout));
		})),
	];

	public static final barrierFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			var count = EvalDecode.decodeInt(v);
			// port: uv_barrier_init: pthread_barrier_init fails with EINVAL for a count of 0
			count == 0 ? errorIndex(LuvSync.EINVAL) : ok(VHandle(HBarrier(new LuvBarrier(count))));
		})),
		f("destroy", EvalEncode.vfun1(v -> {
			decodeBarrier(v);
			VNull;
		})),
		f("wait", EvalEncode.vfun1(v -> {
			decodeBarrier(v).wait().vbool();
		})),
	];

	// port: ---- Env, Time, Path, Random, Network
	public static final envFields:Array<{name:String, value:Value}> = [
		f("getEnv", EvalEncode.vfun1(v -> {
			var name = EvalDecode.decodeString(v);
			switch Uv.getEnv(name) {
				case null: error(Uv.lastError());
				case s: ok(s.vnativeString());
			}
		})),
		f("setEnv", EvalEncode.vfun2((v1, v2) -> {
			var name = EvalDecode.decodeString(v1);
			var value = EvalDecode.decodeNativeString(v2);
			encodeUnitResult(Uv.setEnv(name, value));
		})),
		f("unsetEnv", EvalEncode.vfun1(v -> {
			var name = EvalDecode.decodeString(v);
			encodeUnitResult(Uv.setEnv(name, null));
		})),
		f("environ", EvalEncode.vfun0(() -> {
			switch Uv.environ() {
				case null: error(Uv.lastError());
				case env:
					var map = new RuntimeStringHashtbl<Value>();
					for (i in 0...env.length >> 1) map.add(EvalString.createUnknownVstring(env[2 * i]),
						(env[2 * i + 1] : Bytes).vnativeString());
					ok(EvalEncode.encodeStringMapDirect(map));
			}
		})),
	];

	public static final timeFields:Array<{name:String, value:Value}> = [
		f("getTimeOfDay", EvalEncode.vfun0(() -> {
			var usec = Uv.getTimeOfDay();
			encodeResult(usec, usec -> EvalEncode.encodeObj([
				{name: EvalHash.key_sec, value: VInt64(i64())},
				{name: EvalHash.key_usec, value: usec.vint32()}
			]));
		})),
		f("hrTime", EvalEncode.vfun0(() -> {
			Uv.hrTime();
			VUInt64(i64());
		})),
		f("sleep", EvalEncode.vfun1(v -> {
			Uv.sleep(EvalDecode.decodeInt(v));
			VNull;
		})),
	];

	static function pathResult(which:Int):Value {
		return switch Uv.path(which) {
			case null: error(Uv.lastError());
			case s: ok(s.vnativeString());
		}
	}

	public static final pathFields:Array<{name:String, value:Value}> = [
		f("exePath", EvalEncode.vfun0(() -> pathResult(0))),
		f("cwd", EvalEncode.vfun0(() -> pathResult(1))),
		f("chdir", EvalEncode.vfun1(v -> {
			encodeUnitResult(Uv.chdir(EvalDecode.decodeNativeString(v)));
		})),
		f("homedir", EvalEncode.vfun0(() -> pathResult(2))),
		f("tmpdir", EvalEncode.vfun0(() -> pathResult(3))),
	];

	public static final randomFields:Array<{name:String, value:Value}> = [
		f("createRequest", EvalEncode.vfun0(() -> {
			VHandle(HRandomRequest(Uv.reqNew()));
		})),
		f("random", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var loop = decodeLoop(v1);
			var buffer = decodeBuffer(v2);
			var request = EvalDecode.decodeOptional(v -> switch v {
				case VHandle(HRandomRequest(r)): (r : Int);
				case v: EvalExceptions.unexpectedValue(v, "eval.luv.Random.RandomRequest");
			}, v3);
			var callback = encodeCallback(v4);
			// port: Random.random
			var release = request == null;
			var req = request == null ? Uv.reqNew() : request;
			requestCallbacks.set(req, status -> {
				if (status >= 0) Uv.reqCopyOut(req, buffer.bytes, buffer.offset, 0, buffer.length);
				catchExceptions(callback, encodeUnitResult(status));
				if (release) Uv.reqFree(req);
			});
			var r = Uv.random(loop, req, buffer.length);
			if (r < 0) {
				requestCallbacks.remove(req);
				if (release) Uv.reqFree(req);
				callback(error(r));
			}
			VNull;
		})),
	];

	public static final randomSyncFields:Array<{name:String, value:Value}> = [
		f("random", EvalEncode.vfun1(v -> {
			var buffer = decodeBuffer(v);
			var req = Uv.reqNew();
			var r = Uv.random(-1, req, buffer.length);
			if (r >= 0) Uv.reqCopyOut(req, buffer.bytes, buffer.offset, 0, buffer.length);
			Uv.reqFree(req);
			encodeUnitResult(r);
		})),
	];

	public static final networkFields:Array<{name:String, value:Value}> = [
		f("interfaceAddresses", EvalEncode.vfun0(() -> {
			switch Uv.interfaceAddresses() {
				case null: error(Uv.lastError());
				case a:
					ok(EvalEncode.encodeArray([
						for (i in 0...Std.int(a.length / 5))
							EvalEncode.encodeObj([
								{name: EvalHash.key_name, value: EvalEncode.encodeString(a[5 * i])},
								{name: EvalHash.key_isInternal, value: (a[5 * i + 1] : Bool).vbool()},
								{name: EvalHash.key_physical, value: (a[5 * i + 2] : Bytes).vnativeString()},
								{name: EvalHash.key_address, value: encodeSockaddr(a[5 * i + 3])},
								{name: EvalHash.key_netmask, value: encodeSockaddr(a[5 * i + 4])},
							])
					]));
			}
		})),
		f("ifIndexToName", EvalEncode.vfun1(v -> {
			var index = EvalDecode.decodeInt(v);
			switch Uv.netName(0, index) {
				case null: error(Uv.lastError());
				case s: ok(EvalEncode.encodeString(s));
			}
		})),
		f("ifIndexToIid", EvalEncode.vfun1(v -> {
			var index = EvalDecode.decodeInt(v);
			switch Uv.netName(1, index) {
				case null: error(Uv.lastError());
				case s: ok(EvalEncode.encodeString(s));
			}
		})),
		f("getHostName", EvalEncode.vfun0(() -> {
			switch Uv.netName(2, 0) {
				case null: error(Uv.lastError());
				case s: ok(EvalEncode.encodeString(s));
			}
		})),
	];

	// port: ---- FsPoll
	public static final fsPollFields:Array<{name:String, value:Value}> = [
		f("init", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			encodeResult(Uv.handleInit(HK_FS_POLL, loop, 0, 0), p -> VHandle(HFsPoll(p)));
		})),
		f("start", EvalEncode.vfun4((v1, v2, v3, v4) -> {
			var poll = decodeFsPoll(v1);
			var path = EvalDecode.decodeNativeString(v2);
			var interval = EvalDecode.decodeOptional(EvalDecode.decodeInt, v3);
			var callback = encodeCallback(v4);
			// port: FS_poll.start (the default interval is 2000 ms)
			callbacks(poll).data = (status, b) -> {
				var result = if (status < 0) error(status) else {
						var a:Array<Dynamic> = b;
						ok(EvalEncode.encodeObj([
							{name: EvalHash.key_previous, value: encodeFileStat(a[0])},
							{name: EvalHash.key_current, value: encodeFileStat(a[1])}
						]));
					}
				catchExceptions(callback, result);
			};
			var r = Uv.fsPollStart(poll, path, interval == null ? 2000 : interval);
			if (r < 0) callback(error(r));
			VNull;
		})),
		f("stop", EvalEncode.vfun1(v -> {
			var poll = decodeFsPoll(v);
			encodeUnitResult(Uv.fsPollStop(poll));
		})),
	];

	// port: ---- Resource, SystemInfo, Pid, Passwd, Metrics

	static function memoryValue(which:Int):Value {
		Uv.memory(which);
		var m = i64();
		return m == 0 ? VNull : VUInt64(m);
	}

	public static final resourceFields:Array<{name:String, value:Value}> = [
		f("uptime", EvalEncode.vfun0(() -> {
			var t = Uv.uptime();
			encodeResult(Uv.lastError(), _ -> t.vfloat());
		})),
		f("loadAvg",
			EvalEncode.vfun0(() -> {
				var a = Uv.loadAvg();
				EvalEncode.encodeArrayA([a[0].vfloat(), a[1].vfloat(), a[2].vfloat()]);
			})),
		f("freeMemory", EvalEncode.vfun0(() -> memoryValue(0))),
		f("totalMemory", EvalEncode.vfun0(() -> memoryValue(1))),
		f("constrainedMemory", EvalEncode.vfun0(() -> memoryValue(2))),
		f("getPriority", EvalEncode.vfun1(v -> {
			var pid = EvalDecode.decodeInt(v);
			var p = Uv.getPriority(pid);
			encodeResult(Uv.lastError(), _ -> p.vint());
		})),
		f("setPriority", EvalEncode.vfun2((v1, v2) -> {
			var pid = EvalDecode.decodeInt(v1);
			var priority = EvalDecode.decodeInt(v2);
			encodeUnitResult(Uv.setPriority(pid, priority));
		})),
		f("residentSetMemory", EvalEncode.vfun0(() -> {
			Uv.memory(3);
			var m = i64();
			encodeResult(Uv.lastError(), _ -> EvalIntegers.encodeSizeT(m));
		})),
		f("getRUsage", EvalEncode.vfun0(() -> {
			var b = Bytes.alloc(144);
			encodeResult(Uv.getRUsage(b), _ -> {
				inline function timeval(i:Int):Value {
					return EvalEncode.encodeObj([
						{name: EvalHash.key_sec, value: VInt64(b.getInt64(8 * i))},
						{name: EvalHash.key_usec, value: VInt64(b.getInt64(8 * (i + 1)))}
					]);
				}
				inline function u(i:Int):Value return VUInt64(b.getInt64(8 * i));
				EvalEncode.encodeObjS([
					{name: "utime", value: timeval(0)},
					{name: "stime", value: timeval(2)},
					{name: "maxrss", value: u(4)},
					{name: "ixrss", value: u(5)},
					{name: "idrss", value: u(6)},
					{name: "isrss", value: u(7)},
					{name: "minflt", value: u(8)},
					{name: "majflt", value: u(9)},
					{name: "nswap", value: u(10)},
					{name: "inblock", value: u(11)},
					{name: "oublock", value: u(12)},
					{name: "msgsnd", value: u(13)},
					{name: "msgrcv", value: u(14)},
					{name: "nsignals", value: u(15)},
					{name: "nvcsw", value: u(16)},
					{name: "nivcsw", value: u(17)},
				]);
			});
		})),
	];

	public static final systemInfoFields:Array<{name:String, value:Value}> = [
		f("cpuInfo", EvalEncode.vfun0(() -> {
			switch Uv.cpuInfo() {
				case null: error(Uv.lastError());
				case a:
					ok(EvalEncode.encodeArray([
						for (i in 0...Std.int(a.length / 3)) {
							var t:Bytes = a[3 * i + 2];
							inline function u(k:Int):Value return VUInt64(t.getInt64(8 * k));
							EvalEncode.encodeObjS([
								{name: "model", value: EvalEncode.encodeString(a[3 * i])},
								{name: "speed", value: (a[3 * i + 1] : Int).vint()},
								{
									name: "times",
									value: EvalEncode.encodeObjS([
										{name: "user", value: u(0)},
										{name: "nice", value: u(1)},
										{name: "sys", value: u(2)},
										{name: "idle", value: u(3)},
										{name: "irq", value: u(4)},
									])
								}
							]);
						}
					]));
			}
		})),
		f("uname", EvalEncode.vfun0(() -> {
			switch Uv.uname() {
				case null: error(Uv.lastError());
				case u:
					ok(EvalEncode.encodeObjS([
						{name: "sysname", value: EvalEncode.encodeString(u[0])},
						{name: "release", value: EvalEncode.encodeString(u[1])},
						{name: "version", value: EvalEncode.encodeString(u[2])},
						{name: "machine", value: EvalEncode.encodeString(u[3])},
					]));
			}
		})),
	];

	public static final pidFields:Array<{name:String, value:Value}> = [
		f("getPid", EvalEncode.vfun0(() -> Uv.getPid().vint())),
		f("getPPid", EvalEncode.vfun0(() -> Uv.getPPid().vint())),
	];

	public static final passwdFields:Array<{name:String, value:Value}> = [
		f("getPasswd", EvalEncode.vfun0(() -> {
			switch Uv.getPasswd() {
				case null: error(Uv.lastError());
				case p:
					ok(EvalEncode.encodeObjS([
						{name: "username", value: EvalEncode.encodeString(p[0])},
						{name: "uid", value: (p[1] : Int).vint()},
						{name: "gid", value: (p[2] : Int).vint()},
						{name: "shell", value: EvalEncode.encodeNullable(EvalEncode.encodeString, (p[3] : Null<String>))},
						{name: "homedir", value: (p[4] : Bytes).vnativeString()},
					]));
			}
		})),
	];

	public static final metricsFields:Array<{name:String, value:Value}> = [
		f("idleTime", EvalEncode.vfun1(v -> {
			var loop = decodeLoop(v);
			Uv.metricsIdleTime(loop);
			VUInt64(i64());
		})),
	];

	public static final prepareFields = watcherFields(HK_PREPARE, decodePrepare, i -> HPrepare(i));
	public static final checkFields = watcherFields(HK_CHECK, decodeCheck, i -> HCheck(i));

	public static final versionFields:Array<{name:String, value:Value}> = [
		f("string", EvalEncode.vfun0(() -> EvalEncode.encodeString(Uv.versionString()))),
		f("major", Uv.constant(9, 0).vint()),
		f("minor", Uv.constant(9, 1).vint()),
		f("patch", Uv.constant(9, 2).vint()),
		f("isRelease", (Uv.constant(9, 3) != 0).vbool()),
		f("suffix", EvalEncode.encodeString(Uv.versionSuffix())),
		f("hex", Uv.constant(9, 4).vint()),
	];

	// port: the field lists to register: unchanged when libuv is available, otherwise
	// every entry fails with the not-supported error. (The thread and
	// synchronization lists are registered as they are.)
	public static function fields(l:Array<{name:String, value:Value}>):Array<{name:String, value:Value}> {
		if (available()) return l;
		return [for (e in l) {name: e.name, value: VFunction(_ -> notSupported(), true)}];
	}
}

// port: the callbacks luv keeps in a handle (`Handle.set_reference`).
class LuvHandleCallbacks {
	public var close:Null<Void->Void>;
	public var cb:Null<Int->Void>;
	public var connection:Null<Int->Void>;
	public var allocate:Null<Int->Int>;
	public var data:Null<(Int, Dynamic) -> Void>;
	public var exit:Null<(Int64, Int) -> Void>;

	public function new() {}
}

// port: `Luv.Buffer.t`: a one-dimensional char Bigarray, here a view on a Bytes.
class LuvBuffer {
	public final bytes:Bytes;
	public final offset:Int;
	public final length:Int;

	public function new(bytes:Bytes, offset:Int, length:Int) {
		this.bytes = bytes;
		this.offset = offset;
		this.length = length;
	}

	public static function create(size:Int):LuvBuffer return new LuvBuffer(Bytes.alloc(size), 0, size);

	// port: `Array1.sub`.
	public function sub(offset:Int, length:Int):LuvBuffer {
		if (offset < 0 || length < 0 || offset + length > this.length) throw new InvalidArgument("Bigarray.sub: bad sub-array");
		return new LuvBuffer(bytes, this.offset + offset, length);
	}
}

// port: `Luv.Process.redirection`: child fd, kind (1 pipe, 2 fd, 3 stream), pipe flags, fd or stream.
class LuvRedirection {
	public final fd:Int;
	public final kind:Int;
	public final flags:Int;
	public final value:Int;

	public function new(fd:Int, kind:Int, flags:Int, value:Int) {
		this.fd = fd;
		this.kind = kind;
		this.flags = flags;
		this.value = value;
	}
}

// port: `Luv.Thread.t` (a `uv_thread_t`): a host thread. There is one object per
// host thread, so `Thread.equal` is physical equality. `finished` (threads
// made by `Thread.create`) is released when the thread's function returns.
class LuvThreadHandle {
	static final current = new sys.thread.Tls<LuvThreadHandle>();

	final finished:Null<sys.thread.Lock>;
	var joined = false;

	function new(finished:Null<sys.thread.Lock>) {
		this.finished = finished;
	}

	// port: `Thread.self`.
	public static function self():LuvThreadHandle {
		var t = current.value;
		if (t == null) {
			t = new LuvThreadHandle(null);
			current.value = t;
		}
		return t;
	}

	// port: `Thread.create`: `fn` runs on a new host thread.
	public static function create(fn:Void->Void):LuvThreadHandle {
		var finished = new sys.thread.Lock();
		var t = new LuvThreadHandle(finished);
		EvalLock.activate();
		sys.thread.Thread.create(() -> {
			current.value = t;
			EvalLock.enter();
			try {
				fn();
			} catch (e:Dynamic) {
				EvalLock.leave();
				finished.release();
				throw e;
			}
			EvalLock.leave();
			finished.release();
		});
		return t;
	}

	// port: `Thread.join`: 0 or a luv error index. Joining the calling thread fails
	// (pthread_join's EDEADLK, which luv reports as `UNKNOWN`); a thread not
	// made by `Thread.create` is waited for forever (it is never joinable
	// before the process exits). Joining again returns at once.
	public function join():Int {
		if (current.value == this) return LuvSync.UNKNOWN;
		if (joined) return LuvSync.ESRCH; // port: the thread is gone
		if (finished == null) {
			new sys.thread.Lock().wait();
			return 0;
		}
		finished.wait();
		joined = true;
		return 0;
	}
}

// port: `Luv.Thread_pool.Request.t`.
class LuvWorkRequest {
	// port: 0 never queued, 1 queued, 2 running, 3 done or cancelled (LuvThreadPool's guard).
	public var state = 0;

	public var work:Null<Void->Void>;

	// port: called when the work completes or is cancelled: 0 or a luv error index.
	public var done:Null<Int->Void>;

	public function new() {}
}

// port: libuv's thread pool for `ThreadPool.queueWork`: `UV_THREADPOOL_SIZE`
// (default 4, read when the first work is queued) host threads take queued
// work in order. The work runs Eval code, so it holds `EvalLock` and does not
// run in parallel with other Eval code (libuv's own pool still serves the file
// system and DNS requests).
class LuvThreadPool {
	static final guard = new sys.thread.Mutex();
	static var queue:Null<sys.thread.Deque<LuvWorkRequest>>;

	public static function queueWork(r:LuvWorkRequest):Void {
		guard.acquire();
		if (queue == null) start();
		r.state = 1;
		guard.release();
		queue.add(r);
	}

	// port: `uv_cancel` of a work request: 0 or a luv error index.
	public static function cancel(r:LuvWorkRequest):Int {
		guard.acquire();
		var state = r.state;
		if (state == 1) r.state = 3;
		guard.release();
		return switch state {
			case 0: LuvSync.EINVAL; // port: not a work request yet
			case 1:
				r.done(LuvSync.ECANCELED);
				0;
			case _: LuvSync.EBUSY;
		}
	}

	static function start():Void {
		var size = switch Sys.getEnv("UV_THREADPOOL_SIZE") {
			case null: 4;
			case s:
				var n = Std.parseInt(s);
				n == null ? 0 : n;
		}
		// port: libuv: at least 1, at most 1024
		if (size < 1) size = 1;
		if (size > 1024) size = 1024;
		var q = new sys.thread.Deque<LuvWorkRequest>();
		queue = q;
		EvalLock.activate();
		for (_ in 0...size) sys.thread.Thread.create(() -> worker(q));
	}

	static function worker(q:sys.thread.Deque<LuvWorkRequest>):Void {
		while (true) {
			var r = q.pop(true);
			guard.acquire();
			var run = r.state == 1;
			if (run) r.state = 2;
			guard.release();
			if (!run) continue; // port: cancelled
			EvalLock.enter();
			try r.work()
			catch (e:Dynamic) {
				EvalLock.leave();
				throw e;
			}
			EvalLock.leave();
			guard.acquire();
			r.state = 3;
			guard.release();
			r.done(0);
		}
	}
}

// port: luv's `Mutex`, `Rwlock`, `Semaphore`, `Condition`, `Barrier` and `Once`
// over host threads: a guard mutex for the state, and a Lock per waiting
// thread, released to wake it (which then checks the state again). They do
// not need libuv, and a waiting thread gives up `EvalLock`. Results are 0 or
// a luv `Error.t` index (evalLuv.ml encode_uv_error order), for the error
// codes libuv returns.
class LuvSync {
	public static inline final EAGAIN = 5;
	public static inline final EBUSY = 22;
	public static inline final ECANCELED = 23;
	public static inline final EINVAL = 34;
	public static inline final ESRCH = 67;
	public static inline final ETIMEDOUT = 68;
	public static inline final UNKNOWN = 71;

	final guard = new sys.thread.Mutex();
	var waiters:Array<sys.thread.Lock> = [];

	public function new() {}

	// port: with the guard held: waits (guard released) until woken or `timeout` seconds pass; false on timeout.
	function await(?timeout:Float):Bool {
		var l = new sys.thread.Lock();
		waiters.push(l);
		guard.release();
		var r = EvalLock.blocking(() -> l.wait(timeout));
		guard.acquire();
		if (!r && waiters.remove(l) == false) r = true; // port: woken meanwhile
		return r;
	}

	function wakeOne():Void {
		if (waiters.length > 0) waiters.shift().release();
	}

	function wakeAll():Void {
		var all = waiters;
		waiters = [];
		for (l in all) l.release();
	}
}

// port: `uv_mutex_t`: locking a non-recursive mutex the thread holds deadlocks, as with pthreads.
class LuvMutex extends LuvSync {
	final recursive:Bool;
	var owner:Null<LuvThreadHandle>;
	var depth = 0;

	public function new(recursive:Bool) {
		super();
		this.recursive = recursive;
	}

	public function lock():Void {
		var cur = LuvThreadHandle.self();
		guard.acquire();
		if (owner == cur && recursive) {
			depth++;
		} else {
			while (owner != null) await();
			owner = cur;
			depth = 1;
		}
		guard.release();
	}

	public function tryLock():Int {
		var cur = LuvThreadHandle.self();
		guard.acquire();
		var r = 0;
		if (owner == null) {
			owner = cur;
			depth = 1;
		} else if (owner == cur && recursive) {
			depth++;
		} else {
			r = LuvSync.EBUSY;
		}
		guard.release();
		return r;
	}

	public function unlock():Void {
		guard.acquire();
		if (depth > 1) {
			depth--;
		} else {
			owner = null;
			depth = 0;
			wakeOne();
		}
		guard.release();
	}
}

// port: `uv_rwlock_t` (readers are not held back by waiting writers, as glibc's default).
class LuvRwLock extends LuvSync {
	var readers = 0;
	var writer = false;

	public function rdLock():Void {
		guard.acquire();
		while (writer) await();
		readers++;
		guard.release();
	}

	public function rdTryLock():Int {
		guard.acquire();
		var r = writer ? LuvSync.EBUSY : 0;
		if (r == 0) readers++;
		guard.release();
		return r;
	}

	public function rdUnlock():Void {
		guard.acquire();
		if (readers > 0) readers--;
		if (readers == 0) wakeAll();
		guard.release();
	}

	public function wrLock():Void {
		guard.acquire();
		while (writer || readers > 0) await();
		writer = true;
		guard.release();
	}

	public function wrTryLock():Int {
		guard.acquire();
		var r = writer || readers > 0 ? LuvSync.EBUSY : 0;
		if (r == 0) writer = true;
		guard.release();
		return r;
	}

	public function wrUnlock():Void {
		guard.acquire();
		writer = false;
		wakeAll();
		guard.release();
	}
}

// port: `uv_sem_t`.
class LuvSemaphore extends LuvSync {
	var count:Int;

	public function new(count:Int) {
		super();
		this.count = count;
	}

	public function post():Void {
		guard.acquire();
		count++;
		wakeOne();
		guard.release();
	}

	public function wait():Void {
		guard.acquire();
		while (count <= 0) await();
		count--;
		guard.release();
	}

	public function tryWait():Int {
		guard.acquire();
		var r = count <= 0 ? LuvSync.EAGAIN : 0;
		if (r == 0) count--;
		guard.release();
		return r;
	}
}

// port: `uv_cond_t`.
class LuvCondition extends LuvSync {
	public function signal():Void {
		guard.acquire();
		wakeOne();
		guard.release();
	}

	public function broadcast():Void {
		guard.acquire();
		wakeAll();
		guard.release();
	}

	public function wait(mutex:LuvMutex):Void {
		timedWaitSeconds(mutex, null);
	}

	// port: `uv_cond_timedwait`: `timeout` in nanoseconds.
	public function timedWait(mutex:LuvMutex, timeout:Int):Int {
		return timedWaitSeconds(mutex, Math.max(0.0, timeout / 1e9)) ? 0 : LuvSync.ETIMEDOUT;
	}

	function timedWaitSeconds(mutex:LuvMutex, timeout:Null<Float>):Bool {
		guard.acquire();
		var l = new sys.thread.Lock();
		waiters.push(l);
		guard.release();
		mutex.unlock();
		var r = EvalLock.blocking(() -> l.wait(timeout));
		if (!r) {
			guard.acquire();
			if (waiters.remove(l) == false) r = true; // port: signalled meanwhile
			guard.release();
		}
		mutex.lock();
		return r;
	}
}

// port: `uv_barrier_t`: `wait` is true in one thread per cycle, the last to arrive.
class LuvBarrier extends LuvSync {
	final count:Int;
	var arrived = 0;
	var cycle = 0;

	public function new(count:Int) {
		super();
		this.count = count;
	}

	public function wait():Bool {
		guard.acquire();
		var c = cycle;
		arrived++;
		var serial = arrived >= count;
		if (serial) {
			arrived = 0;
			cycle++;
			wakeAll();
		} else {
			while (cycle == c) await();
		}
		guard.release();
		return serial;
	}
}

// port: `uv_once_t`: other threads calling `once` meanwhile wait until the function has run.
class LuvOnce extends LuvSync {
	var state = 0; // port: 0 not run, 1 running, 2 done

	public function once(f:Void->Void):Void {
		guard.acquire();
		if (state == 0) {
			state = 1;
			guard.release();
			inline function finish() {
				guard.acquire();
				state = 2;
				wakeAll();
				guard.release();
			}
			try {
				f();
			} catch (e:Dynamic) {
				finish();
				throw e;
			}
			finish();
		} else {
			while (state != 2) await();
			guard.release();
		}
	}
}

#if !(target.name == "hxmc") // port: hosts without libuv: `EvalLuv.available()` is false and no field reaches these.
private class Uv {
	static function no():Dynamic return throw new Failure("libuv is not available on this host");

	public static function available():Bool return false;

	public static function lastError():Int return no();

	public static function i64Hi():Int return no();

	public static function i64Lo():Int return no();

	public static function errIndex(code:Int):Int return no();

	public static function errCode(index:Int):Int return no();

	public static function strerror(code:Int):String return no();

	public static function errName(code:Int):String return no();

	public static function translateSysError(e:Int):Int return no();

	// port: evaluated while the field lists are built; the values are discarded by `EvalLuv.fields`
	public static function constant(group:Int, index:Int):Int return 0;

	public static function versionString():String return "";

	public static function versionSuffix():String return "";

	public static function loopDefault():Int return no();

	public static function loopInit():Int return no();

	public static function loopRun(loop:Int, mode:Int, dispatcher:(Int, Int, Int, Dynamic) -> Void):Bool return no();

	public static function loopStop(loop:Int):Void no();

	public static function loopClose(loop:Int):Int return no();

	public static function loopAlive(loop:Int):Bool return no();

	public static function loopNow(loop:Int):Void no();

	public static function loopUpdateTime(loop:Int):Void no();

	public static function libraryShutdown():Void no();

	public static function metricsIdleTime(loop:Int):Void no();

	public static function handleInit(kind:Int, loop:Int, arg:Int, arg2:Int):Int return no();

	public static function handleClose(handle:Int):Bool return no();

	public static function handleIsActive(handle:Int):Bool return no();

	public static function handleIsClosing(handle:Int):Bool return no();

	public static function handleRef(handle:Int):Void no();

	public static function handleUnref(handle:Int):Void no();

	public static function handleHasRef(handle:Int):Bool return no();

	public static function bufferSize(handle:Int, send:Bool, size:Int):Int return no();

	public static function watcherStart(handle:Int):Int return no();

	public static function watcherStop(handle:Int):Int return no();

	public static function timerStart(handle:Int, timeout:Int, repeat:Int):Int return no();

	public static function timerStop(handle:Int):Int return no();

	public static function timerAgain(handle:Int):Int return no();

	public static function timerSetRepeat(handle:Int, repeat:Int):Void no();

	public static function timerGetRepeat(handle:Int):Int return no();

	public static function timerGetDueIn(handle:Int):Int return no();

	public static function asyncSend(handle:Int):Int return no();

	public static function signalStart(handle:Int, signum:Int, oneshot:Bool):Int return no();

	public static function signalStop(handle:Int):Int return no();

	public static function signalSignum(handle:Int):Int return no();

	public static function reqNew():Int return no();

	public static function reqFree(req:Int):Void no();

	public static function reqCancel(req:Int):Int return no();

	public static function reqCopyOut(req:Int, b:Bytes, pos:Int, src:Int, len:Int):Void no();

	public static function sockaddrSize():Int return no();

	public static function sockaddrIp(host:String, port:Int, v6:Bool, out:Bytes):Int return no();

	public static function sockaddrPort(sa:Bytes):Int return no();

	public static function sockaddrToString(sa:Bytes):Null<String> return no();

	public static function tcpNoDelay(handle:Int, b:Bool):Int return no();

	public static function tcpKeepAlive(handle:Int, enable:Bool, delay:Int):Int return no();

	public static function tcpSimultaneousAccepts(handle:Int, b:Bool):Int return no();

	public static function tcpBind(handle:Int, sa:Bytes, ipv6only:Bool):Int return no();

	public static function sockName(handle:Int, peer:Bool, out:Bytes):Int return no();

	public static function tcpConnect(handle:Int, sa:Bytes, req:Int):Int return no();

	public static function tcpCloseReset(handle:Int, req:Int):Int return no();

	public static function allocSize(n:Int):Void no();

	public static function streamShutdown(handle:Int, req:Int):Int return no();

	public static function streamListen(handle:Int, backlog:Int):Int return no();

	public static function streamAccept(server:Int, client:Int):Int return no();

	public static function readStart(handle:Int):Int return no();

	public static function readStop(handle:Int):Int return no();

	public static function streamWrite(handle:Int, req:Int, data:Bytes, sizes:Array<Int>, sendHandle:Int):Int return no();

	public static function streamTryWrite(handle:Int, data:Bytes, sizes:Array<Int>):Int return no();

	public static function streamWriteQueueSize(handle:Int):Int return no();

	public static function streamIsReadable(handle:Int):Bool return no();

	public static function streamIsWritable(handle:Int):Bool return no();

	public static function streamSetBlocking(handle:Int, b:Bool):Int return no();

	public static function pipeBind(handle:Int, name:Bytes):Int return no();

	public static function pipeConnect(handle:Int, name:Bytes, req:Int):Void no();

	public static function pipeName(handle:Int, peer:Bool):Null<Bytes> return no();

	public static function pipePendingInstances(handle:Int, n:Int):Void no();

	public static function pipePendingType(handle:Int):Int return no();

	public static function pipeChmod(handle:Int, mode:Int):Int return no();

	public static function ttySetMode(handle:Int, mode:Int):Int return no();

	public static function ttyResetMode():Int return no();

	public static function ttyGetWinSize(handle:Int):Null<Array<Int>> return no();

	public static function ttySetVTermState(state:Int):Void no();

	public static function ttyGetVTermState():Int return no();

	public static function udpBind(handle:Int, sa:Bytes, flags:Int):Int return no();

	public static function udpConnect(handle:Int, sa:Null<Bytes>):Int return no();

	public static function udpSetMembership(handle:Int, group:String, iface:String, source:Null<String>, join:Bool):Int return no();

	public static function udpSetOption(handle:Int, option:Int, value:Int):Int return no();

	public static function udpSetMulticastInterface(handle:Int, iface:String):Int return no();

	public static function udpSend(handle:Int, req:Int, data:Bytes, sizes:Array<Int>, sa:Null<Bytes>):Int return no();

	public static function udpTrySend(handle:Int, data:Bytes, sizes:Array<Int>, sa:Null<Bytes>):Int return no();

	public static function udpRecvStart(handle:Int):Int return no();

	public static function udpRecvStop(handle:Int):Int return no();

	public static function udpSendQueue(handle:Int, count:Bool):Int return no();

	public static function processSpawn(loop:Int, cmd:Bytes, args:Array<Bytes>, env:Null<Array<Bytes>>, cwd:Null<Bytes>, flags:Int,
			uid:Int, gid:Int, redirect:Array<Int>, onExit:Bool):Int return no();

	public static function disableStdioInheritance():Void no();

	public static function killPid(pid:Int, signum:Int):Int return no();

	public static function processPid(handle:Int):Int return no();

	public static function getAddrInfo(loop:Int, req:Int, node:Null<String>, service:Null<String>, family:Int, socktype:Int, protocol:Int,
			flags:Int, hasHints:Bool):Int return no();

	public static function addrInfoResult(req:Int):Array<Dynamic> return no();

	public static function getNameInfo(loop:Int, req:Int, sa:Bytes, flags:Int):Int return no();

	public static function nameInfoResult(req:Int):Array<String> return no();

	public static function fs(op:Int, loop:Int, req:Int, p1:Null<Bytes>, p2:Null<Bytes>, i1:Int, i2:Int, i3:Int, f1:Float, f2:Float,
			data:Null<Bytes>, sizes:Null<Array<Int>>):Int return no();

	public static function fsResult(req:Int):Int return no();

	public static function fsCleanup(req:Int):Void no();

	public static function fsPath(req:Int):Null<Bytes> return no();

	public static function fsPtrString(req:Int):Null<Bytes> return no();

	public static function fsStat(req:Int, out:Bytes):Void no();

	public static function fsStatfs(req:Int, out:Bytes):Void no();

	public static function fsDir(req:Int):Int return no();

	public static function fsDirents(req:Int):Array<Dynamic> return no();

	public static function fsScandirNext(req:Int):Null<Array<Dynamic>> return no();

	public static function fsEventStart(handle:Int, path:Bytes, flags:Int):Int return no();

	public static function fsEventStop(handle:Int):Int return no();

	public static function fsPollStart(handle:Int, path:Bytes, interval:Int):Int return no();

	public static function fsPollStop(handle:Int):Int return no();

	public static function random(loop:Int, req:Int, len:Int):Int return no();

	public static function getEnv(name:String):Null<Bytes> return no();

	public static function setEnv(name:String, value:Null<Bytes>):Int return no();

	public static function environ():Null<Array<Dynamic>> return no();

	public static function getTimeOfDay():Int return no();

	public static function hrTime():Void no();

	public static function sleep(ms:Int):Void no();

	public static function path(which:Int):Null<Bytes> return no();

	public static function chdir(dir:Bytes):Int return no();

	public static function interfaceAddresses():Null<Array<Dynamic>> return no();

	public static function netName(which:Int, index:Int):Null<String> return no();

	public static function uptime():Float return no();

	public static function loadAvg():Array<Float> return no();

	public static function memory(which:Int):Void no();

	public static function getPriority(pid:Int):Int return no();

	public static function setPriority(pid:Int, priority:Int):Int return no();

	public static function getRUsage(out:Bytes):Int return no();

	public static function cpuInfo():Null<Array<Dynamic>> return no();

	public static function uname():Null<Array<String>> return no();

	public static function getPid():Int return no();

	public static function getPPid():Int return no();

	public static function getPasswd():Null<Array<Dynamic>> return no();
}
#end
