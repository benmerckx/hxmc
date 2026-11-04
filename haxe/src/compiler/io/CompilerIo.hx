package compiler.io;

import haxe.io.Input;
import haxe.io.Output;

/** Abstract IO handle for a compilation request. */
typedef CompilerIoData = {
	var stdout:Output;
	var stderr:Output;
	var stdin:Input;
	var getch:Bool->Int;
	var writeOut:String->Void;
	var writeErr:String->Void;
	var writeResult:String->Void;
	var signalError:Void->Void;
	var flush:Void->Void;
	var close:Void->Void;
}

/** Compiler IO abstraction.

	This module provides the IO channels and protocol-aware output routing
	for a single compilation request.

	The protocol encoding is fully encapsulated via generic callbacks. */
class CompilerIo {
	/* Create a Unix pipe with a background reader thread that forwards chunks
		to [write_fn].  Returns [(out_channel, thread)]. */
	// port: a PipeOutput stands in for the Unix pipe and is both the channel and the thread
	// to join: it hands the reader's chunks (at most 1024 bytes, in order) to [write_fn] as
	// they are flushed, on the writer's thread, without a reader thread (joined at once)
	public static function makeOutputPipe(writeFn:String->Void):{output:Output, thread:PipeOutput} {
		var output = new PipeOutput(writeFn);
		return {output: output, thread: output};
	}

	public static function getchFromChannel(input:Input, output:Output, echo:Bool):Int {
		var c = try input.readByte() catch (_:haxe.io.Eof) -1;
		if (echo && c >= 0) {
			output.writeByte(c);
			output.flush();
		}
		return c;
	}

	public static function writeOut(io:CompilerIoData, s:String):Void io.writeOut(s);

	public static function writeErr(io:CompilerIoData, s:String):Void io.writeErr(s);

	public static function writeResult(io:CompilerIoData, s:String):Void io.writeResult(s);

	public static function signalError(io:CompilerIoData):Void io.signalError();

	public static function getStdout(io:CompilerIoData):Output return io.stdout;

	public static function getStderr(io:CompilerIoData):Output return io.stderr;

	public static function getStdin(io:CompilerIoData):Input return io.stdin;

	public static function getch(io:CompilerIoData, echo:Bool):Int return io.getch(echo);

	public static function flush(io:CompilerIoData):Void io.flush();

	public static function close(io:CompilerIoData):Void io.close();

	/** Create a pipe-backed IO handle with explicit callbacks. */
	public static function create(writeOut:String->Void, writeErr:String->Void, writeResult:String->Void, signalError:Void->Void,
			stdin:Input):CompilerIoData {
		var out = makeOutputPipe(writeOut), err = makeOutputPipe(writeErr), closed = false;
		return {
			stdout: out.output,
			stderr: err.output,
			stdin: stdin,
			getch: function(echo) return getchFromChannel(stdin, out.output, echo),
			writeOut: writeOut,
			writeErr: writeErr,
			writeResult: writeResult,
			signalError: signalError,
			flush: function() {
				out.output.flush();
				err.output.flush();
			},
			close: function() {
				if (!closed) {
					closed = true;
					out.output.flush();
					try out.output.close()
					catch (_:Dynamic) {}
					out.thread.join();
					err.output.flush();
					try err.output.close()
					catch (_:Dynamic) {}
					err.thread.join();
					try stdin.close()
					catch (_:Dynamic) {}
				}
			}
		};
	}

	/** Create a stdio-based IO handle for non-server (CLI) mode. */
	public static function createStdioIo():CompilerIoData return {
		stdout: Sys.stdout(),
		stderr: Sys.stderr(),
		stdin: Sys.stdin(),
		getch: Sys.getChar,
		writeOut: function(s) {
			Sys.print(s);
			Sys.stdout().flush();
		},
		writeErr: function(s) {
			Sys.stderr().writeString(s);
			Sys.stderr().flush();
		},
		writeResult: function(s) Sys.stderr().writeString(s),
		signalError: function() {},
		flush: function() Sys.stdout().flush(),
		close: function() {}
	};
}

private class PipeOutput extends Output {
	final writeFn:String->Void;
	var closed = false;

	public function new(writeFn:String->Void) {
		this.writeFn = writeFn;
	}

	// port: like an OCaml out_channel, writes are buffered (65536 bytes) until flushed;
	// the pipe then delivers them in chunks of at most 1024 bytes. [write_fn] takes a
	// string, which on some hosts (JavaScript) cannot hold part of a UTF-8 sequence: a
	// chunk ends between sequences, and an incomplete one at the end waits for the next
	// flush (upstream's reader cuts the bytes wherever a read ends: the client joins them).
	var buffer = new haxe.io.BytesBuffer();

	static inline var CHANNEL_BUFFER_SIZE = 65536;

	override public function writeByte(byte:Int):Void {
		var bytes = haxe.io.Bytes.alloc(1);
		bytes.set(0, byte);
		writeBytes(bytes, 0, 1);
	}

	override public function writeBytes(bytes:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (closed) throw haxe.io.Error.Custom("Output is closed");
		if (pos < 0 || len < 0 || pos + len > bytes.length) throw haxe.io.Error.OutsideBounds;
		buffer.addBytes(bytes, pos, len);
		if (buffer.length >= CHANNEL_BUFFER_SIZE) flush();
		return len;
	}

	override public function flush():Void {
		deliver(false);
	}

	function deliver(all:Bool):Void {
		if (buffer.length == 0) return;
		var bytes = buffer.getBytes();
		buffer = new haxe.io.BytesBuffer();
		var end = all ? bytes.length : bytes.length - incompleteTail(bytes);
		var pos = 0;
		while (pos < end) {
			var n = Std.int(Math.min(end - pos, 1024));
			if (pos + n < end) {
				var cut = n;
				while (cut > n - 3 && bytes.get(pos + cut) & 0xC0 == 0x80) cut--;
				if (cut > 0) n = cut;
			}
			writeFn(bytes.sub(pos, n).toString());
			pos += n;
		}
		if (end < bytes.length) buffer.addBytes(bytes, end, bytes.length - end);
	}

	// port: the length of a UTF-8 sequence cut off at the end of [bytes] (0 if none)
	static function incompleteTail(bytes:haxe.io.Bytes):Int {
		var i = bytes.length;
		while (i > 0 && bytes.length - i < 3) {
			var b = bytes.get(--i);
			if (b & 0xC0 == 0x80) continue;
			var len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
			return i + len > bytes.length ? bytes.length - i : 0;
		}
		return 0;
	}

	override public function close():Void {
		if (!closed) {
			deliver(true);
			closed = true;
		}
	}

	public function join():Void {}
}
