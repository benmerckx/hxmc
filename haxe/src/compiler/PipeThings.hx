package compiler;

import haxe.io.Bytes;
import haxe.io.Input;
import compiler.io.CompilerIo;

/** Handles IO piping between the compilation server and its clients.

	In server mode, the compiler runs as a long-lived process.  Client
	requests arrive over a socket, and we need to redirect the compilation's
	stdin/stdout/stderr through the socket rather than using the server
	process's own file descriptors.

	Protocol encoding (how stdout/stderr/errors are multiplexed) is handled
	by {!CompilerIo} via its opaque {!CompilerIo.protocol} type.  This module
	provides the client-side socket communication ([poll], [ssend]) and the
	server-side subprocess runner ({!run_command}).

	Stdin data from the client is forwarded as raw bytes after the null-terminated
	argument string, so newlines in stdin require no special encoding. */
// port: Haxe inputs cannot be polled with `Unix.select`. `run_command` forwards the
// server-side stdin only when it is a `ForwardedInput` (the client stdin forwarded by
// `Server`) and polls its queue; `poll` reads descriptor 0 through `RawStdin` and
// joins the forwarding thread only when `RawStdin.interruptible`.
class PipeThings {
	/** Reads all available data from [channel] in 1024-byte chunks,
		passing each chunk to [f]. Stops on EOF or Unix error. */
	public static function readContent(channel:Input, buf:Bytes, f:String->Void):Void {
		while (true) {
			var i = try channel.readBytes(buf, 0, 1024) catch (_:Dynamic) 0;
			if (i > 0) f(buf.sub(0, i).toString())
			else break;
		}
	}

	/** Runs a shell command in server mode, forwarding stdin from the client
		and capturing stdout/stderr through the socket protocol.
		The command runs in [cwd] if given, otherwise in the current directory.
		Uses {!Process.run} to create the child process so we can connect
		the child's stdin to the client's forwarded data and properly signal
		EOF when the client closes its end. */
	// port: sys.io.Process stands in for Process.run (EvalProcess.hostProcess).
	public static function runCommand(io:CompilerIoData, cmd:String, ?cwd:String):Int {
		var writeOut = function(s) CompilerIo.writeOut(io, s);
		var writeErr = function(s) CompilerIo.writeErr(io, s);
		var proc = macros.eval.EvalProcess.hostProcess(cmd, null, cwd);
		var pout = proc.stdout;
		var pin = proc.stdin;
		var perr = proc.stderr;
		var bout = Bytes.alloc(1024);
		var berr = Bytes.alloc(1024);
		/* Use a flag to signal the stdin-forwarding thread to stop.
			The thread uses Unix.select with a timeout so it can check this flag
			periodically, avoiding a hang when the child exits but the client
			hasn't closed its stdin (e.g. interactive use or partial writes). */
		var stopStdin = false;
		var tin = switch CompilerIo.getStdin(io) {
			case stdinPipe if (Std.isOfType(stdinPipe, ForwardedInput)):
				var stdinPipe:ForwardedInput = cast stdinPipe;
				var done = new sys.thread.Lock();
				sys.thread.Thread.create(function() {
					try {
						while (!stopStdin) {
							var chunk = stdinPipe.poll(0.05);
							if (chunk != null) {
								if (chunk.length == 0) throw new haxe.io.Eof();
								pin.write(chunk);
								pin.flush();
							}
						}
					} catch (_:Dynamic) {}
					try pin.close()
					catch (_:Dynamic) {}
					done.release();
				});
				done;
			case _:
				try pin.close()
				catch (_:Dynamic) {}
				null;
		}
		var toutDone = new sys.thread.Lock(), terrDone = new sys.thread.Lock();
		sys.thread.Thread.create(function() {
			readContent(pout, bout, writeOut);
			toutDone.release();
		});
		sys.thread.Thread.create(function() {
			readContent(perr, berr, writeErr);
			terrDone.release();
		});
		/* Join stdout/stderr threads first — they complete when the child closes
			its output fds (typically on exit). Then reap the child process, signal
			the stdin thread to stop, and join it. */
		toutDone.wait();
		terrDone.wait();
		var code = proc.exitCode();
		stopStdin = true;
		if (tin != null) tin.wait();
		proc.close();
		return code;
	}

	public static function ssend(sock:sys.net.Socket, str:Bytes):Void {
		sock.output.writeFullBytes(str, 0, str.length);
		sock.output.flush();
	}

	public static function poll(sock:sys.net.Socket, print:String->Void):Void {
		var responseBuf = new haxe.io.BytesBuffer();
		function lines(s:String):Array<String> {
			var lines = s.split("\n");
			if (lines.length > 0 && lines[lines.length - 1] == "") lines.pop();
			return lines;
		}
		/* Process all complete lines (up to the last newline) in the buffer,
			keeping any partial unflushed line for the next read. */
		function flushCompleteLines() {
			var bytes = responseBuf.getBytes();
			var lastNl = -1;
			for (i in 0...bytes.length) if (bytes.get(i) == "\n".code) lastNl = i;
			responseBuf = new haxe.io.BytesBuffer();
			if (lastNl < 0) {
				responseBuf.add(bytes);
				return;
			}
			var complete = bytes.getString(0, lastNl + 1);
			for (line in lines(complete)) print(line);
			if (lastNl + 1 < bytes.length) responseBuf.addBytes(bytes, lastNl + 1, bytes.length - lastNl - 1);
		}
		/* Forward stdin to the server socket in a background thread.
			Using a dedicated thread avoids mixing socket and non-socket file
			descriptors in Unix.select, which has known issues on Windows. */
		var stdinBuf = Bytes.alloc(1024);
		var stopStdin = false;
		var stdinDone = new sys.thread.Lock();
		sys.thread.Thread.create(function() {
			try {
				while (!stopStdin) {
					var n = RawStdin.read(stdinBuf, 0.05);
					if (n == 0) {
						try sock.shutdown(false, true)
						catch (_:Dynamic) {}
						break;
					}
					if (n > 0) ssend(sock, stdinBuf.sub(0, n));
				}
			} catch (_:Dynamic) {}
			stdinDone.release();
		});
		/* Read server output until the connection closes, printing lines immediately
			as they arrive rather than waiting for the server to disconnect. */
		var sockBuf = Bytes.alloc(1024);
		var sockOpen = true;
		while (sockOpen) {
			var b = try sock.input.readBytes(sockBuf, 0, 1024) catch (_:Dynamic) 0;
			if (b <= 0)
				sockOpen = false
			else {
				responseBuf.addBytes(sockBuf, 0, b);
				flushCompleteLines();
			}
		}
		stopStdin = true;
		if (RawStdin.interruptible) stdinDone.wait();
		/* Flush any remaining partial line after the server closes the connection */
		var s = responseBuf.getBytes().toString();
		if (s != "") {
			for (line in lines(s)) print(line);
		}
	}
}

// port: the client's stdin as `Unix.select` + `Unix.read` on descriptor 0 see it
// (PipeThings.poll). `read` returns the byte count read (at most the buffer
// length, as soon as any data is available), 0 at end of input, or -1 when
// nothing arrived within [timeout] seconds.
//
// Haxe's `Sys.stdin()` is a C `FILE`; reading it blocks until the whole buffer
// is filled and holds the stream lock, so glibc's `exit` (which locks every
// stream to flush it) hangs while the forwarding thread waits for input. On
// HashLink, descriptor 0 is polled through the std library's `select` and read
// with `read(2)` (the natives behind sys.net.Socket.select and sys.io.Process,
// given a handle whose descriptor is 0). Elsewhere it falls back to byte reads
// of `Sys.stdin()`, which cannot be interrupted (`interruptible` is false: the
// thread is not joined).
class RawStdin {
	#if hl
	public static inline final interruptible = true;
	// port: hl_socket { int sock } and vprocess { finalize; int oread; ... } with descriptor 0
	static var socket:Null<hl.Abstract<"hl_socket">> = null;
	static var process:Null<hl.Abstract<"hl_process">> = null;
	static var selectTmp:Null<hl.Bytes> = null;

	public static function read(buf:Bytes, timeout:Float):Int {
		if (socket == null) {
			var s = new hl.Bytes(16), p = new hl.Bytes(32);
			s.fill(0, 16, 0);
			p.fill(0, 32, 0);
			socket = hl.Api.unsafeCast(s);
			process = hl.Api.unsafeCast(p);
			selectTmp = new hl.Bytes(1024);
		}
		var set = new hl.NativeArray<hl.Abstract<"hl_socket">>(1);
		set[0] = socket;
		if (!socketSelect(set, null, null, selectTmp, 1024, timeout)) return 0;
		if (set[0] == null) return -1;
		var n = processRead(process, buf, 0, buf.length);
		return n <= 0 ? 0 : n;
	}

	@:hlNative("std", "socket_select") static function socketSelect(read:hl.NativeArray<hl.Abstract<"hl_socket">>,
			write:hl.NativeArray<hl.Abstract<"hl_socket">>, other:hl.NativeArray<hl.Abstract<"hl_socket">>, tmpData:hl.Bytes, tmpSize:Int,
			timeout:Float):Bool return false;

	@:hlNative("std", "process_stdout_read") static function processRead(p:hl.Abstract<"hl_process">, bytes:hl.Bytes, pos:Int,
			len:Int):Int return 0;
	#else
	public static inline final interruptible = false;

	public static function read(buf:Bytes, timeout:Float):Int {
		try {
			buf.set(0, Sys.stdin().readByte());
			return 1;
		} catch (_:haxe.io.Eof) {
			return 0;
		}
	}
	#end
}

// port: server-side stdin of a request: bytes the client sends after its
// null-terminated arguments, fed by a forwarding thread. Upstream uses a Unix
// pipe (`SocketRequest.setup_client_stdin_forward`); here a queue of chunks,
// with an empty chunk marking end of input.
class ForwardedInput extends Input {
	final queue = new sys.thread.Deque<Bytes>();
	var current:Null<Bytes> = null;
	var pos = 0;
	var eof = false;

	public function new() {}

	public function push(chunk:Bytes):Void {
		queue.add(chunk);
	}

	public function finish():Void {
		queue.add(Bytes.alloc(0));
	}

	// port: returns the next chunk, an empty chunk at end of input, or null after [timeout] seconds.
	public function poll(timeout:Float):Null<Bytes> {
		if (current != null && pos < current.length) {
			var chunk = current.sub(pos, current.length - pos);
			current = null;
			return chunk;
		}
		if (eof) return Bytes.alloc(0);
		var chunk = queue.pop(false);
		if (chunk == null) {
			Sys.sleep(timeout);
			chunk = queue.pop(false);
		}
		if (chunk != null && chunk.length == 0) eof = true;
		return chunk;
	}

	override public function readByte():Int {
		while (current == null || pos >= current.length) {
			if (eof) throw new haxe.io.Eof();
			current = queue.pop(true);
			pos = 0;
			if (current.length == 0) {
				eof = true;
				current = null;
				throw new haxe.io.Eof();
			}
		}
		return current.get(pos++);
	}

	override public function readBytes(s:Bytes, p:Int, len:Int):Int {
		if (len == 0) return 0;
		var first = readByte();
		s.set(p, first);
		var n = 1;
		while (n < len && current != null && pos < current.length) {
			s.set(p + n, current.get(pos++));
			n++;
		}
		return n;
	}
}
