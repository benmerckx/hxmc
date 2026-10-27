package compiler.server;

import haxe.io.Bytes;
import haxe.io.Input;
import compiler.Args;
import compiler.ParsedArg;
import compiler.PipeThings;
import compiler.io.CompilerIo;
import compiler.io.CompilerOutput;
import context.Common;
import core.ds.ArgumentError;
import core.ds.Failure;
import core.ds.Cancelled;
import core.Timer;

// port: Unix sockets become `sys.net.Socket`, the worker domain a
// `sys.thread.Thread`, `Semaphore.Counting` a `sys.thread.Semaphore`, and the
// stdin pipe of a request a `PipeThings.ForwardedInput`. `Unix.Unix_error`
// corresponds to the host's socket exceptions (anything but `haxe.io.Eof`,
// which is OCaml's zero-length read). The host socket API has IPv4 only, and no
// `getsockopt SO_ERROR`; a failed write closes the connection instead. The worker
// domain's minor heap setup (Gc.set) is not ported.
typedef ServerConnection = {
	var read:Void->String;
	var write:String->Void;
	var close:Void->Void;
	var getStdin:Void->Input;
}

typedef ServerAccept = Void->ServerConnection;

// port: `Ipaddr.t`: the address of `--wait`/`--connect` (see `haxe.Main.parseHostPort`).
enum IpAddr {
	V4(ip:String);
	V6(ip:String);
}

@:structInit class Request {
	public var args:Array<ParsedArg>;
	public var stdin:Null<String>;
	public var conn:ServerConnection;
}

class RequestQueue {
	public final mutex = new sys.thread.Mutex();
	public final semaphore = new sys.thread.Semaphore(0);
	public var requests:Array<Request> = [];
	public var shutdownFlag = false;
	public var cancelToken = false;

	public function new() {}

	public static function create():RequestQueue {
		return new RequestQueue();
	}

	public static function wakeUp(rq:RequestQueue):Void {
		rq.semaphore.release();
	}

	public static function add(rq:RequestQueue, args:Array<ParsedArg>, stdin:Null<String>, conn:ServerConnection):Void {
		rq.mutex.acquire();
		rq.requests.unshift({args: args, stdin: stdin, conn: conn});
		rq.mutex.release();
		wakeUp(rq);
	}

	public static function shutdown(rq:RequestQueue):Void {
		rq.cancelToken = true;
		rq.shutdownFlag = true;
		wakeUp(rq);
	}
}

enum RequestOutcome {
	Success;
	Cancelled;
	Errored;
	Oom;
}

class Server {
	public static function makeClosedStdin():Input {
		var stdin = new ForwardedInput();
		stdin.finish();
		return stdin;
	}

	// port: IO.read_i32: little-endian signed 32-bit
	static function readI32(input:Input):Int {
		input.bigEndian = false;
		return input.readInt32();
	}

	public static function mkLengthPrefixedCommunication(allowNonblock:Bool, sock:sys.net.Socket):ServerAccept {
		sock.setBlocking(true);
		var chin = sock.input;
		var chout = sock.output;

		var bout = new StringBuf();

		function read():String {
			var len = readI32(chin);
			return chin.read(len).toString();
		}

		// port: OCaml's threads run one at a time (the runtime lock), so the
		// pipe threads of CompilerIo (stdout and stderr) never append to the
		// buffer at once; the host's threads run in parallel: a lock
		var lock = new sys.thread.Mutex();
		function write(s:String):Void {
			lock.acquire();
			bout.add(s);
			lock.release();
		}

		function close() {
			Sys.stdout().flush();
			lock.acquire();
			try {
				var data = Bytes.ofString(bout.toString());
				chout.bigEndian = false;
				chout.writeInt32(data.length);
				chout.writeFullBytes(data, 0, data.length);
				chout.flush();
				bout = new StringBuf();
			} catch (e:Dynamic) {
				lock.release();
				throw e;
			}
			lock.release();
		}

		return function() {
			var stdin = makeClosedStdin();
			return {
				read: read,
				write: write,
				close: close,
				getStdin: () -> stdin
			};
		}
	}

	/* The connect function to connect to [host] at [port] and send arguments [args]. */
	public static function doConnect(ip:IpAddr, port:Int, args:Array<ParsedArg>):Int {
		var host = switch ip {
			case V4(ip): ip;
			case V6(ip): throw new Failure("IPv6 addresses are not supported by the host socket API (" + ip + ")");
		}
		var sock = new sys.net.Socket();
		try {
			sock.connect(new sys.net.Host(host), port);
		} catch (e:Dynamic) {
			throw new Failure("Couldn't connect on " + host + ":" + port + " (" + connectErrorMessage(e) + ")");
		}
		var rawArgs = ["--cwd " + core.Path.removeTrailingSlash(Sys.getCwd())].concat(Args.toRawArgs(args));
		var s = rawArgs.map(a -> a + "\n").join("");
		PipeThings.ssend(sock, Bytes.ofString(s + "\x00"));
		var hasError = false;
		function print(line:String) {
			switch (if (line == "") 0 else line.charCodeAt(0)) {
				case 0x01:
					Sys.stdout().writeString(line.split("\x01").slice(1).join("\n"));
					Sys.stdout().flush();
				case 0x02:
					hasError = true;
				case _:
					Sys.stderr().writeString(line + "\n");
					Sys.stderr().flush();
			}
		}
		PipeThings.poll(sock, print);
		return if (hasError) 1 else 0;
	}

	// port: Unix.error_message of the failed connect; the host reports "Failed to connect".
	static function connectErrorMessage(e:Dynamic):String {
		var s = Std.string(e);
		return if (s.indexOf("Failed to connect") >= 0) "Connection refused" else s;
	}

	// port: module SocketRequest
	public static function setupClientStdinForward(overflow:Bytes, sin:sys.net.Socket):Input {
		/* Set up stdin forwarding: create a pipe and a thread that reads
			from the client socket and writes to the pipe. */
		var stdin = new ForwardedInput();
		sys.thread.Thread.create(function() {
			var buf = Bytes.alloc(1024);
			try {
				/* Write any overflow data read past the null terminator */
				if (overflow.length > 0)
					stdin.push(overflow);
				/* Forward data from client socket to stdin pipe */
				while (true) {
					var n = sin.input.readBytes(buf, 0, 1024);
					if (n == 0) throw core.ds.Exit.raise();
					stdin.push(buf.sub(0, n));
				}
			} catch (_:Dynamic) {}
			stdin.finish();
		});
		return stdin;
	}

	/* Reads a null-terminated request from a non-blocking socket, tracking any
		overflow data received past the null terminator (e.g. stdin data from the client). */
	public static function socketRequestRead(overflow:{value:Bytes}, sin:sys.net.Socket, bufsize:Int):String {
		var tmp = Bytes.alloc(bufsize);
		var b = new haxe.io.BytesBuffer();
		function readLoop(count:Int):String {
			var r = try {
				sin.input.readBytes(tmp, 0, bufsize);
			} catch (e:haxe.io.Eof) {
				0;
			} catch (e:haxe.io.Error) {
				switch e {
					case Blocked:
						if (count == 100) throw new Failure("Aborting inactive connection"); else {
							ServerMessage.socketMessage("Waiting for data...");
							Sys.sleep(0.05);
							return readLoop(count + 1);
						}
					case _:
						throw e;
				}
			}
			if (r == 0)
				throw new Failure("Incomplete request");
			else {
				ServerMessage.socketMessage("Reading " + r + " bytes\n");
				var nullPos = -1;
				for (i in 0...r) if (tmp.get(i) == 0) {
					nullPos = i;
					break;
				}
				if (nullPos >= 0) {
					b.addBytes(tmp, 0, nullPos);
					var remaining = r - nullPos - 1;
					if (remaining > 0)
						overflow.value = tmp.sub(nullPos + 1, remaining);
					return b.getBytes().toString();
				} else {
					b.addBytes(tmp, 0, r);
					return readLoop(0);
				}
			}
		}
		var data = readLoop(0);
		/* Switch to blocking mode before spawning the stdin forwarding thread.
			The socket was set to non-blocking for the request-parsing phase above
			(to handle slow clients with retries), but the forwarding thread needs
			blocking recv to avoid exiting prematurely on EWOULDBLOCK. */
		sin.setBlocking(true);
		return data;
	}

	public static function createRequestScope(isServer:Bool, io:CompilerIoData, displayArg:Null<String>):RequestScope {
		var timerCtx = Timer.makeContext(Timer.make(["other"]));
		var resultHandler = switch displayArg {
			case null:
				if (isServer) CompilerOutput.createServerResultHandler(io) else CompilerOutput.createCliResultHandler(io);
			case arg:
				core.json.JsonRpc.handleJsonrpcError(function() {
					var input = core.json.JsonRpc.parseRequest(arg);
					return context.display.DisplayJson.createJsonResultHandler(timerCtx, io, new core.json.JsonrpcHandler(input));
				}, function(json) {
					context.display.DisplayJson.sendJson(io, json);
					throw core.ds.Exit.raise();
				});
		}
		return {
			stats: Stats.create(),
			timerCtx: timerCtx,
			cancellationRequested: false,
			io: io,
			resultHandler: resultHandler
		};
	}

	public static function process(sctx:ServerCompilationContext, requestScope:RequestScope, requestArgs:RequestArgs):Void {
		var t0 = Sys.time();
		var curdir = Sys.getCwd();
		ServerMessage.arguments(Args.stringOfRequestArgs(requestArgs));
		ServerCompilationContext.reset(sctx);
		if (sctx.persistentCwd != null) try Sys.setCwd(sctx.persistentCwd)
		catch (_:Dynamic) {}
		try {
			HighLevel.entry(sctx, requestScope, requestArgs);
		} catch (e:Dynamic) {
			core.Path.restoreCwd(curdir);
			throw e;
		}
		core.Path.restoreCwd(curdir);
		ServerCompilationContext.runDelays(sctx);
		ServerMessage.stats(requestScope.stats, Sys.time() - t0);
	}

	// port: module WorkerDomain
	static function workerShutdown(rq:RequestQueue):Void {
		/* Drain remaining requests by closing their connections, then return
			without recursing to exit the loop gracefully. */
		rq.mutex.acquire();
		var pending = rq.requests;
		rq.requests = [];
		rq.mutex.release();
		for (req in pending) {
			var conn = req.conn;
			/* No CompilerIo.t exists for pending requests, so signal error
				directly through the raw connection using v1 protocol encoding. */
			try conn.write("\x02\nServer shutdown\n")
			catch (_:Dynamic) {}
			conn.close();
		}
	}

	static function createRequestIo(request:Request):CompilerIoData {
		var conn = request.conn;
		function writeOut(s:String) conn.write("\x01" + s.split("\n").join("\x01") + "\n");
		function writeErr(s:String) conn.write(s);
		function writeResult(s:String) conn.write(s);
		function signalError() conn.write("\x02\n");
		return CompilerIo.create(writeOut, writeErr, writeResult, signalError, conn.getStdin());
	}

	// port: Printexc.to_string
	static function exceptionString(e:Dynamic):String {
		if (Std.isOfType(e, Failure)) return "Failure(\"" + (e : Failure).message + "\")";
		if (Std.isOfType(e, core.ds.NotFound)) return "Not_found";
		if (Std.isOfType(e, haxe.Exception)) return (e : haxe.Exception).message;
		return Std.string(e);
	}

	static function runRequest(sctx:ServerCompilationContext, io:CompilerIoData, request:Request):RequestOutcome {
		sctx.currentStdin = request.stdin;
		try {
			var requestArgs = Args.expandArgs(request.args);
			var requestScope = createRequestScope(true, io, requestArgs.displayArg);
			process(sctx, requestScope, requestArgs);
			return Success;
		} catch (e:Cancelled) {
			ServerMessage.uncaughtError("Compilation cancelled");
			try {
				CompilerIo.signalError(io);
				CompilerIo.writeErr(io, "Cancelled\n");
			} catch (_:Dynamic) {}
			return Cancelled;
		} catch (e:ArgumentError) {
			try {
				CompilerIo.signalError(io);
				CompilerIo.writeErr(io, e.message);
			} catch (_:Dynamic) {}
			return Errored;
		} catch (e:core.ds.Exit) {
			/* From JSON-RPC failure */
			return Errored;
		} catch (e:Dynamic) {
			var estr = exceptionString(e);
			ServerMessage.uncaughtError(estr);
			try {
				CompilerIo.signalError(io);
				CompilerIo.writeErr(io, estr + "\n");
			} catch (_:Dynamic) {}
			if (Helper.isDebugRun) Sys.println(estr + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			// port: Out_of_memory: the host reports it as an ordinary error
			return if (estr == "Out of memory") Oom else Errored;
		}
	}

	static function createWorker(sctx:ServerCompilationContext, rq:RequestQueue):sys.thread.Lock {
		var finished = new sys.thread.Lock();
		sys.thread.Thread.create(function() {
			var cs = sctx.cs;
			function loop() {
				while (true) {
					// port: Eval threads left by a request (--interp) run while the worker waits
					// (it holds the Eval lock otherwise, see macros.eval.EvalLock)
					macros.eval.EvalLock.blocking(() -> {
						rq.semaphore.acquire();
						true;
					});
					/* Check for shutdown before doing any work */
					if (rq.shutdownFlag) {
						workerShutdown(rq);
						return;
					} else {
						rq.mutex.acquire();
						switch rq.requests {
							case []:
								rq.mutex.release();
								if (cs.hasTask()) {
									cs.getTask().run();
									RequestQueue.wakeUp(rq);
								}
							case requests:
								// port: rq.requests is a list consed at the head: take its first element
								var request = requests.shift();
								rq.mutex.release();
								sctx.currentStdin = request.stdin;
								rq.cancelToken = false;
								var io = createRequestIo(request);
								var outcome = runRequest(sctx, io, request);
								CompilerIo.close(io);
								request.conn.close();
								switch outcome {
									case Oom:
										Sys.exit(-1);
									case _:
								}

								sctx.currentStdin = null;
								ServerCache.cleanup(sctx);
								if (sctx.wasCompilation)
									cs.addTask(new compiler.Tasks.ServerExplorationTask(cs));
								RequestQueue.wakeUp(rq);
						}
					}
				}
			}
			loop();
			finished.release();
		});
		return finished;
	}

	public static function setupServerContext(verbose:Bool, isServer:Bool):ServerCompilationContext {
		if (verbose) ServerMessage.enableAll();
		// port: Sys.catch_break is not called (the host owns signal handling).
		/* Create server context and set up hooks for parsing and typing */
		var sctx = ServerCompilationContext.create(verbose, isServer);
		ServerCache.enableCacheMode(sctx);
		return sctx;
	}

	/* The server main loop. Waits for the [accept] call to then process the sent compilation
		parameters through [process_params]. */
	public static function waitLoop(verbose:Bool, accept:ServerAccept):Int {
		var sctx = setupServerContext(verbose, true);
		var rq = RequestQueue.create();
		var worker = createWorker(sctx, rq);
		/* Main loop: accept connections and enqueue requests for the worker.
			The loop exits if the accept function raises an exception (e.g. socket closed). */
		try {
			while (true) {
				var conn = accept();
				try {
					// port: diverges from upstream, where the read's Failure (a client
					// that closes without a request, "Incomplete request", or sends
					// nothing, "Aborting inactive connection") leaves this loop and
					// ends the server (4.3's went on): here it drops the connection.
					var s = try conn.read() catch (e:Failure) {
						ServerMessage.socketMessage("Connection Aborted: " + e.message);
						conn.close();
						continue;
					}
					var idx = s.indexOf("\x01");
					var stdin:Null<String>, hxml:String;
					if (idx >= 0) {
						stdin = s.substr(idx + 1);
						hxml = s.substr(0, idx);
					} else {
						stdin = null;
						hxml = s;
					}
					var data = Helper.parseHxmlData(hxml);
					var parsedArgs = Args.parseArgs(data);
					RequestQueue.add(rq, parsedArgs, stdin, conn);
				} catch (e:Dynamic) {
					if (!isUnixError(e)) throw e;
					ServerMessage.socketMessage("Connection Aborted");
					conn.close();
				}
			}
		} catch (_:Dynamic) {}
		RequestQueue.shutdown(rq);
		worker.wait();
		ServerCompilationContext.dispose(sctx);
		return 0;
	}

	// port: Unix.Unix_error: socket failures other than end of file
	static function isUnixError(e:Dynamic):Bool {
		return Std.isOfType(e, haxe.io.Error) || (Std.isOfType(e, String) && !Std.isOfType(e, Failure));
	}

	/* Connect to given host/port and return accept function for communication */
	public static function initWaitConnect(ip:IpAddr, port:Int):ServerAccept {
		var host = switch ip {
			case V4(ip): ip;
			case V6(ip): throw new Failure("IPv6 addresses are not supported by the host socket API (" + ip + ")");
		}
		var sock = new sys.net.Socket();
		sock.connect(new sys.net.Host(host), port);
		return mkLengthPrefixedCommunication(true, sock);
	}

	/* The accept-function to wait for a socket connection. */
	public static function initWaitSocket(ip:IpAddr, port:Int):ServerAccept {
		var host = switch ip {
			case V4(ip): ip;
			case V6(ip): throw new Failure("IPv6 addresses are not supported by the host socket API (" + ip + ")");
		}
		var sock = new sys.net.Socket();
		// port: SO_REUSEADDR: the host's bind sets it
		try sock.bind(new sys.net.Host(host), port)
		catch (_:Dynamic) throw new Failure("Couldn't wait on " + host + ":" + port);
		ServerMessage.socketMessage("Waiting on " + host + ":" + port);
		sock.listen(10);
		var bufsize = 1024;
		function accept():ServerConnection {
			var sin = sock.accept();
			sin.setBlocking(false);
			ServerMessage.socketMessage("Client connected");
			var overflow = {value: Bytes.alloc(0)};
			var stdinRef = makeClosedStdin();
			function read():String {
				var data = socketRequestRead(overflow, sin, bufsize);
				stdinRef = setupClientStdinForward(overflow.value, sin);
				return data;
			}
			var closed = false;
			function close() {
				if (!closed) {
					closed = true;
					/* Shutdown before close to ensure FIN is sent to the client even if
						the stdin-forwarding thread has a pending recv on the same fd.
						Unix.close alone may not send FIN while another thread blocks on recv. */
					try sin.shutdown(true, true)
					catch (_:Dynamic) {}
					try sin.close()
					catch (_:Dynamic) Sys.println("Error while closing socket.");
				}
			}
			function write(s:String) {
				if (!closed)
					try PipeThings.ssend(sin, Bytes.ofString(s))
					catch (_:Dynamic) close();
			}
			return {
				read: read,
				write: write,
				close: close,
				getStdin: () -> stdinRef
			};
		}
		return accept;
	}
}
