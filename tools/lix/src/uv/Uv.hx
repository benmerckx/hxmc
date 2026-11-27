package uv;

import haxe.io.Bytes;
import hxmc.NativeUv as N;

// A small callback API over libuv (hxmc.NativeUv, hxmc/std/hxmc/rt/Uv.hx) for
// single-threaded programs: handles and requests are integer ids, and their
// events reach the callbacks registered on their loop while the loop runs.

/** A failed libuv call. **/
class UvError extends haxe.Exception {
	public final code:Int;

	public function new(code:Int, ?what:String) {
		this.code = code;
		super((what == null ? '' : '$what: ') + N.strerror(code));
	}

	/** The libuv error name, e.g. `ENOENT`. **/
	public var name(get, never):String;

	function get_name()
		return N.errName(code);

	static public function check(code:Int, ?what:String):Int {
		if (code < 0)
			throw new UvError(code, what);
		return code;
	}
}

enum abstract RunMode(Int) to Int {
	var Default = 0;
	var Once = 1;
	var NoWait = 2;
}

// event kinds of rt_uv.c's dispatcher
enum abstract Event(Int) from Int to Int {
	var Close = 0;
	var Callback = 1;
	var Request = 2;
	var Connection = 3;
	var Alloc = 4;
	var Read = 5;
	var Exit = 6;
	var FsEvent = 8;
}

// handle kinds of rt_uv.c
enum abstract HandleKind(Int) to Int {
	var KTimer = 3;
	var KAsync = 4;
	var KTcp = 5;
	var KPipe = 7;
	var KTty = 8;
	var KSignal = 9;
	var KFsEvent = 11;
}

class Loop {
	public final id:Int;

	final listeners = new Map<Int, (event:Event, a:Int, b:Dynamic) -> Void>();

	static var defaultLoop:Null<Loop>;

	function new(id:Int)
		this.id = id;

	/** The default loop. **/
	static public function get():Loop {
		if (defaultLoop == null)
			defaultLoop = new Loop(UvError.check(N.loopDefault(), 'loop'));
		return defaultLoop;
	}

	/** A new loop, for a run of its own (see `close`). **/
	static public function create():Loop
		return new Loop(UvError.check(N.loopInit(), 'loop'));

	public function listen(id:Int, f:(event:Event, a:Int, b:Dynamic) -> Void)
		listeners.set(id, f);

	public function unlisten(id:Int)
		listeners.remove(id);

	function dispatch(id:Int, event:Int, a:Int, b:Dynamic) {
		var f = listeners.get(id);
		if (f != null)
			f(event, a, b);
	}

	/** Runs the loop; returns whether it is still alive. **/
	public function run(mode:RunMode = Default):Bool
		return N.loopRun(id, mode, dispatch);

	public function stop()
		N.loopStop(id);

	public function alive():Bool
		return N.loopAlive(id);

	/** The loop's time in milliseconds. **/
	public function now():Float {
		N.loopNow(id);
		return N.i64Hi() * 4294967296.0 + (N.i64Lo() >>> 0);
	}

	public function close()
		UvError.check(N.loopClose(id), 'loop close');

	/** A one-shot request: `f` gets the request's status when it completes. **/
	public function request(f:Int->Void):Int {
		var req = N.reqNew();
		listen(req, (_, status, _) -> {
			unlisten(req);
			N.reqFree(req);
			f(status);
		});
		return req;
	}

	/** Frees a request whose operation failed to start. **/
	public function dropRequest(req:Int) {
		unlisten(req);
		N.reqFree(req);
	}

	static public function available():Bool
		return N.available();

	/** This process's id. **/
	static public function pid():Int
		return N.getPid();

	/** What `fd` refers to. **/
	static public function guess(fd:Int):FdKind
		return N.available() ? N.guessHandle(fd) : FUnknown;
}

enum abstract FdKind(Int) from Int {
	var FUnknown = 0;
	var FTty = 1;
	var FPipe = 2;
	var FTcp = 3;
	var FUdp = 4;
	var FFile = 5;
}

class Handle {
	public final loop:Loop;
	public final id:Int;

	var onClose:Null<() -> Void>;
	var closing = false;

	function new(loop:Loop, id:Int) {
		this.loop = loop;
		this.id = UvError.check(id, 'init');
		loop.listen(this.id, event);
	}

	function event(event:Event, a:Int, b:Dynamic) {
		if (event == Close) {
			loop.unlisten(id);
			if (onClose != null)
				onClose();
		}
	}

	public function close(?cb:() -> Void) {
		if (closing)
			return;
		closing = true;
		onClose = cb;
		N.handleClose(id);
	}

	public var isClosing(get, never):Bool;

	function get_isClosing()
		return closing;

	/** The loop does not wait for this handle. **/
	public function unref()
		N.handleUnref(id);
}

class Timer extends Handle {
	var callback:() -> Void;

	public function new(loop:Loop)
		super(loop, N.handleInit(KTimer, loop.id, 0, 0));

	public function start(cb:() -> Void, timeout:Int, repeat = 0) {
		callback = cb;
		UvError.check(N.timerStart(id, timeout, repeat), 'timer');
	}

	public function stop()
		N.timerStop(id);

	override function event(event:Event, a:Int, b:Dynamic)
		if (event == Callback)
			callback();
		else
			super.event(event, a, b);
}

class Signal extends Handle {
	var callback:Int->Void;

	public function new(loop:Loop)
		super(loop, N.handleInit(KSignal, loop.id, 0, 0));

	public function start(signum:Int, cb:Int->Void) {
		callback = cb;
		UvError.check(N.signalStart(id, signum, false), 'signal');
	}

	override function event(event:Event, a:Int, b:Dynamic)
		if (event == Callback)
			callback(a);
		else
			super.event(event, a, b);

	static public inline var SIGINT = 2;
	static public inline var SIGTERM = 15;
}

/** Watches a file or directory for changes. **/
class FsWatcher extends Handle {
	var callback:() -> Void;

	public function new(loop:Loop)
		super(loop, N.handleInit(KFsEvent, loop.id, 0, 0));

	public function start(path:String, cb:() -> Void) {
		callback = cb;
		UvError.check(N.fsEventStart(id, Bytes.ofString(path), 0), 'watch $path');
	}

	override function event(event:Event, a:Int, b:Dynamic)
		if (event == FsEvent)
			callback();
		else
			super.event(event, a, b);
}

class Stream extends Handle {
	static inline var EOF = -4095;
	static inline var READ_SIZE = 65536;

	var onData:Null<Bytes>->Void;
	var onReadError:UvError->Void;
	var onConnection:Int->Void;

	/**
		Starts reading: `data` gets each chunk, then `null` at the end of the
		stream; `error` (default: thrown) a failed read.
	**/
	public function readStart(data:Null<Bytes>->Void, ?error:UvError->Void) {
		onData = data;
		onReadError = error;
		UvError.check(N.readStart(id), 'read');
	}

	public function readStop()
		N.readStop(id);

	/** Writes `data`; `cb` gets the status (0 or a negative error). **/
	public function write(data:Bytes, ?cb:Int->Void) {
		var req = loop.request(status -> if (cb != null) cb(status));
		var r = N.streamWrite(id, req, data, [data.length], 0);
		if (r < 0) {
			loop.dropRequest(req);
			if (cb != null)
				cb(r);
		}
	}

	public function shutdown(?cb:Int->Void) {
		var req = loop.request(status -> if (cb != null) cb(status));
		var r = N.streamShutdown(id, req);
		if (r < 0) {
			loop.dropRequest(req);
			if (cb != null)
				cb(r);
		}
	}

	public function listen(cb:Int->Void, backlog = 128) {
		onConnection = cb;
		UvError.check(N.streamListen(id, backlog), 'listen');
	}

	public function accept(client:Stream)
		UvError.check(N.streamAccept(id, client.id), 'accept');

	override function event(event:Event, a:Int, b:Dynamic)
		switch event {
			case Alloc:
				N.allocSize(READ_SIZE);
			case Read:
				if (a > 0)
					onData(b);
				else if (a == EOF)
					onData(null);
				else if (a < 0) {
					var e = new UvError(a, 'read');
					if (onReadError != null) onReadError(e) else throw e;
				}
			case Connection:
				onConnection(a);
			case _:
				super.event(event, a, b);
		}
}

class Tcp extends Stream {
	public function new(loop:Loop)
		super(loop, N.handleInit(KTcp, loop.id, -1, 0));

	static function address(host:String, port:Int):Bytes {
		var sa = Bytes.alloc(N.sockaddrSize());
		var v6 = host.indexOf(':') != -1;
		UvError.check(N.sockaddrIp(host, port, v6, sa), 'address $host');
		return sa;
	}

	public function bind(host:String, port:Int)
		UvError.check(N.tcpBind(id, address(host, port), false), 'bind $host:$port');

	/** Connects to `host:port` (an IP address); `cb` gets the status. **/
	public function connect(host:String, port:Int, cb:Int->Void) {
		var req = loop.request(cb);
		var r = N.tcpConnect(id, address(host, port), req);
		if (r < 0) {
			loop.dropRequest(req);
			cb(r);
		}
	}

	/** The local port. **/
	public function port():Int {
		var sa = Bytes.alloc(N.sockaddrSize());
		UvError.check(N.sockName(id, false, sa), 'getsockname');
		return N.sockaddrPort(sa);
	}

	public function noDelay(b:Bool)
		N.tcpNoDelay(id, b);
}

class Pipe extends Stream {
	public function new(loop:Loop)
		super(loop, N.handleInit(KPipe, loop.id, 0, 0));

	/** A pipe over the descriptor `fd`, e.g. 0 for stdin. **/
	static public function open(loop:Loop, fd:Int):Pipe {
		var p = new Pipe(loop);
		UvError.check(N.pipeOpen(p.id, fd), 'open fd $fd');
		return p;
	}
}

/** How a child process gets a standard descriptor. **/
enum StdioSpec {
	Ignore;
	Inherit;
	/** A pipe: readable and/or writable from the child's side. **/
	CreatePipe(pipe:Pipe, childReads:Bool, childWrites:Bool);
}

typedef SpawnOptions = {
	?cwd:String,
	/** The whole environment of the child (default: this process's). **/
	?env:Map<String, String>,
	/** stdin, stdout, stderr (default: all inherited). **/
	?stdio:Array<StdioSpec>,
	/** Windows: the command line is the arguments as given, unquoted (libuv's
		UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS), as for cmd.exe /c. **/
	?verbatim:Bool,
}

class Process extends Handle {
	var onExit:(code:Int, signal:Int) -> Void;

	/** Spawns `cmd` (looked up in `PATH`) with `args` (not including `cmd`). **/
	static public function spawn(loop:Loop, cmd:String, args:Array<String>, options:SpawnOptions, onExit:(code:Int, signal:Int) -> Void):Process {
		var argv = [Bytes.ofString(cmd)].concat([for (a in args) Bytes.ofString(a)]);
		var env = switch options.env {
			case null: null;
			case env: [for (k => v in env) Bytes.ofString('$k=$v')];
		}
		var stdio = switch options.stdio {
			case null: [Inherit, Inherit, Inherit];
			case v: v;
		}
		var redirect = [];
		for (fd => spec in stdio)
			switch spec {
				case Ignore:
				case Inherit:
					redirect = redirect.concat([fd, 2, 0, fd]);
				case CreatePipe(pipe, reads, writes):
					redirect = redirect.concat([fd, 1, (reads ? 1 : 0) | (writes ? 2 : 0), pipe.id]);
			}
		var cwd = options.cwd == null ? null : Bytes.ofString(options.cwd);
		var id = N.processSpawn(loop.id, Bytes.ofString(cmd), argv, env, cwd, options.verbatim == true ? 4 : 0, 0, 0, redirect, true);
		if (id < 0)
			throw new UvError(id, 'spawn $cmd');
		var p = new Process(loop, id);
		p.onExit = onExit;
		return p;
	}

	public var pid(get, never):Int;

	function get_pid()
		return N.processPid(id);

	public function kill(signum = 15)
		N.killPid(pid, signum);

	override function event(event:Event, a:Int, b:Dynamic)
		if (event == Exit)
			onExit(a, b)
		else
			super.event(event, a, b);
}

/** Synchronous file system calls std lacks. **/
class Fs {
	// rt_uv.c's FS_* operations
	static inline var CHMOD = 24;
	static inline var LINK = 29;
	static inline var SYMLINK = 30;
	static inline var READLINK = 31;

	static function sync(op:Int, path:String, ?path2:String, i1 = 0):Int {
		var req = N.reqNew();
		var r = N.fs(op, -1, req, Bytes.ofString(path), path2 == null ? null : Bytes.ofString(path2), i1, 0, 0, 0, 0, null, null);
		N.fsCleanup(req);
		N.reqFree(req);
		return r;
	}

	static public function chmod(path:String, mode:Int)
		UvError.check(sync(CHMOD, path, null, mode), 'chmod $path');

	/** Creates a hard link at `path` to the file `target`. **/
	static public function link(target:String, path:String)
		UvError.check(sync(LINK, target, path), 'link $path');

	// uv_fs_symlink's flags (Windows: a directory's link, a junction)
	static public inline var SYMLINK_DIR = 1;
	static public inline var SYMLINK_JUNCTION = 2;

	/** Creates a symbolic link at `path` pointing to `target`. **/
	static public function symlink(target:String, path:String, flags = 0)
		UvError.check(sync(SYMLINK, target, path, flags), 'symlink $path');

	static public function isSymlink(path:String):Bool
		return N.available() && sync(READLINK, path) >= 0;
}
