package ml2hx.prim;

import haxe.io.Bytes;
import ml2hx.rt.*;

// OCaml's io.c over Haxe's sys API: file descriptors (ints, as Unix gives
// them) and buffered channels on them. Strings are byte strings (one unit per
// byte); file names are converted to the host's encoding at the boundary.

// An open file: descriptors 0, 1, 2 are the process's standard streams.
class Fd {
	public final name:String;
	public var input:Null<haxe.io.Input>;
	public var output:Null<haxe.io.Output>;
	// a regular file opened for reading: its bytes, read at open
	public var bytes:Null<Bytes>;
	public var pos = 0;
	public var closed = false;

	public function new(name:String) this.name = name;

	public function close() {
		if (closed) return;
		closed = true;
		if (input != null) input.close();
		if (output != null) output.close();
	}
}

class Channel {
	public final fd:Int;
	public var name:String;
	public var closed = false;
	public var binary = true;

	function new(fd:Int) {
		this.fd = fd;
		name = Io.fd(fd).name;
	}
}

class InChannel extends Channel {
	// lookahead read from a stream (stdin, pipes): consumed before the stream
	var pending:Null<haxe.io.BytesBuffer> = null;
	var pendingBytes:Null<Bytes> = null;
	var pendingPos = 0;
	public var offset = 0;

	public function new(fd:Int) super(fd);

	inline function file():Fd return Io.fd(fd);

	function fill():Bool {
		// one more byte of lookahead from a stream; false at its end
		var f = file();
		if (f.input == null) return false;
		var c = try f.input.readByte() catch (e:haxe.io.Eof) -1;
		if (c < 0) return false;
		var b = new haxe.io.BytesBuffer();
		if (pendingBytes != null) b.addBytes(pendingBytes, pendingPos, pendingBytes.length - pendingPos);
		b.addByte(c);
		pendingBytes = b.getBytes();
		pendingPos = 0;
		return true;
	}

	function available():Int {
		var f = file();
		if (f.bytes != null) return f.bytes.length - f.pos;
		return pendingBytes == null ? 0 : pendingBytes.length - pendingPos;
	}

	function byteAt(k:Int):Int {
		var f = file();
		return f.bytes != null ? f.bytes.get(f.pos + k) : pendingBytes.get(pendingPos + k);
	}

	function consume(n:Int) {
		var f = file();
		if (f.bytes != null) f.pos += n; else pendingPos += n;
		offset += n;
	}

	// the next byte, -1 at the end
	public function readByte():Int {
		check();
		if (available() == 0 && !fill()) return -1;
		var c = byteAt(0);
		consume(1);
		return c;
	}

	public function read(b:Bytes, ofs:Int, n:Int):Int {
		check();
		if (n == 0) return 0;
		if (available() == 0 && !fill()) return 0;
		var k = available();
		if (k > n) k = n;
		var f = file();
		if (f.bytes != null) b.blit(ofs, f.bytes, f.pos, k); else b.blit(ofs, pendingBytes, pendingPos, k);
		consume(k);
		return k;
	}

	// caml_ml_input_scan_line: n > 0 when a newline ends the n buffered bytes,
	// -n when the n bytes before the end have none, 0 at the end
	public function scanLine():Int {
		check();
		var k = 0;
		while (true) {
			if (k == available() && !fill()) return -k;
			if (byteAt(k) == 10) return k + 1;
			k++;
		}
	}

	public function check() if (closed) throw new SysError("Bad file descriptor");
}

class OutChannel extends Channel {
	var buf = Bytes.alloc(65536);
	var len = 0;
	public var offset = 0;
	public var unbuffered:Bool;

	public function new(fd:Int) {
		super(fd);
		unbuffered = fd == 2;
		Io.outs.push(this);
	}

	inline function out():haxe.io.Output {
		var f = Io.fd(fd);
		if (f.closed || f.output == null) throw new SysError("Bad file descriptor");
		return f.output;
	}

	public function check() if (closed) throw new SysError("Bad file descriptor");

	public function addByte(c:Int) {
		check();
		if (len == buf.length) flushBuffer();
		buf.set(len++, c);
		if (unbuffered) flush();
	}

	public function addString(s:String, ofs:Int, n:Int) {
		check();
		for (i in ofs...ofs + n) {
			if (len == buf.length) flushBuffer();
			buf.set(len++, StringTools.fastCodeAt(s, i));
		}
		if (unbuffered) flush();
	}

	public function addBytes(b:Bytes, ofs:Int, n:Int) {
		check();
		if (len + n > buf.length) flushBuffer();
		if (n > buf.length) {
			out().writeFullBytes(b, ofs, n);
			offset += n;
		} else {
			buf.blit(len, b, ofs, n);
			len += n;
		}
		if (unbuffered) flush();
	}

	function flushBuffer() {
		if (len > 0) {
			out().writeFullBytes(buf, 0, len);
			offset += len;
			len = 0;
		}
	}

	public function flush() {
		if (closed) return;
		flushBuffer();
		out().flush();
	}

	public function pos():Int return offset + len;
}

class Io {
	static var fds:Map<Int, Fd> = initFds();
	static var nextFd = 3;
	public static var outs:Array<OutChannel> = [];

	static function initFds():Map<Int, Fd> {
		var m = new Map<Int, Fd>();
		var i = new Fd("");
		i.input = std.Sys.stdin();
		m.set(0, i);
		var o = new Fd("");
		o.output = std.Sys.stdout();
		m.set(1, o);
		var e = new Fd("");
		e.output = std.Sys.stderr();
		m.set(2, e);
		return m;
	}

	public static function fd(n:Int):Fd {
		var f = fds.get(n);
		if (f == null || f.closed) throw new SysError("Bad file descriptor");
		return f;
	}

	public static function addFd(f:Fd):Int {
		var n = nextFd++;
		fds.set(n, f);
		return n;
	}

	public static function closeFd(n:Int) {
		var f = fds.get(n);
		if (f == null || f.closed) throw new SysError("Bad file descriptor");
		f.close();
		fds.remove(n);
	}

	static inline function i(n:Int63):Int return n.toInt();

	// channels over Haxe streams (sockets, pipes, processes)
	public static function inOfInput(input:haxe.io.Input, name = ""):InChannel {
		var f = new Fd(name);
		f.input = input;
		return new InChannel(addFd(f));
	}
	public static function outOfOutput(output:haxe.io.Output, name = ""):OutChannel {
		var f = new Fd(name);
		f.output = output;
		return new OutChannel(addFd(f));
	}

	public static function camlMlOpenDescriptorIn(fd:Int63):InChannel return new InChannel(i(fd));
	public static function camlMlOpenDescriptorOut(fd:Int63):OutChannel return new OutChannel(i(fd));

	public static function camlMlOutChannelsList(_:Unit):MlList<OutChannel> {
		var l = MlList.Nil;
		for (c in outs) if (!c.closed) l = MlList.Cons(c, l);
		return l;
	}

	public static function camlMlOutput(oc:OutChannel, s:String, ofs:Int63, len:Int63):Unit {
		oc.addString(s, i(ofs), i(len));
		return Unit.value;
	}
	public static function camlMlOutputBytes(oc:OutChannel, b:Bytes, ofs:Int63, len:Int63):Unit {
		oc.addBytes(b, i(ofs), i(len));
		return Unit.value;
	}
	public static function camlMlOutputChar(oc:OutChannel, c:Int63):Unit {
		oc.addByte(c.toInt64().low & 255);
		return Unit.value;
	}
	public static function camlMlOutputInt(oc:OutChannel, n:Int63):Unit {
		var v = n.toInt64().low;
		oc.addByte((v >> 24) & 255);
		oc.addByte((v >> 16) & 255);
		oc.addByte((v >> 8) & 255);
		oc.addByte(v & 255);
		return Unit.value;
	}
	public static function camlMlFlush(c:Channel):Unit {
		if (c is OutChannel) (cast c : OutChannel).flush();
		return Unit.value;
	}

	public static function camlMlInput(ic:InChannel, b:Bytes, ofs:Int63, len:Int63):Int63
		return Int63.ofInt(ic.read(b, i(ofs), i(len)));
	public static function camlMlInputChar(ic:InChannel):Int63 {
		var c = ic.readByte();
		if (c < 0) throw EndOfFile.instance;
		return Int63.ofInt(c);
	}
	public static function camlMlInputInt(ic:InChannel):Int63 {
		var v = 0;
		for (_ in 0...4) {
			var c = ic.readByte();
			if (c < 0) throw EndOfFile.instance;
			v = (v << 8) | c;
		}
		return Int63.ofInt(v);
	}
	public static function camlMlInputScanLine(ic:InChannel):Int63 return Int63.ofInt(ic.scanLine());

	public static function camlMlPosIn(ic:InChannel):Int63 return Int63.ofInt(ic.offset);
	public static function camlMlPosIn_64(ic:InChannel):haxe.Int64 return ic.offset;
	public static function camlMlPosOut(oc:OutChannel):Int63 return Int63.ofInt(oc.pos());
	public static function camlMlPosOut_64(oc:OutChannel):haxe.Int64 return oc.pos();

	public static function camlMlSeekIn(ic:InChannel, n:Int63):Unit return seekIn(ic, i(n));
	public static function camlMlSeekIn_64(ic:InChannel, n:haxe.Int64):Unit return seekIn(ic, haxe.Int64.toInt(n));
	static function seekIn(ic:InChannel, n:Int):Unit {
		var f = fd(ic.fd);
		if (f.bytes == null) throw new SysError("Illegal seek");
		f.pos = n;
		ic.offset = n;
		return Unit.value;
	}
	public static function camlMlSeekOut(oc:OutChannel, n:Int63):Unit return seekOut(oc, i(n));
	public static function camlMlSeekOut_64(oc:OutChannel, n:haxe.Int64):Unit return seekOut(oc, haxe.Int64.toInt(n));
	static function seekOut(oc:OutChannel, n:Int):Unit {
		oc.flush();
		var f = fd(oc.fd);
		if (!(f.output is sys.io.FileOutput)) throw new SysError("Illegal seek");
		(cast f.output : sys.io.FileOutput).seek(n, SeekBegin);
		oc.offset = n;
		return Unit.value;
	}

	public static function camlMlChannelSize(c:Channel):Int63 return Int63.ofInt(size(c));
	public static function camlMlChannelSize_64(c:Channel):haxe.Int64 return size(c);
	static function size(c:Channel):Int {
		var f = fd(c.fd);
		if (f.bytes != null) return f.bytes.length;
		if (c is OutChannel) {
			var oc:OutChannel = cast c;
			if (f.output is sys.io.FileOutput) {
				oc.flush();
				return Std.int(sys.FileSystem.stat(ByteString.toNative(f.name)).size);
			}
		}
		throw new SysError("Illegal seek");
	}

	public static function camlMlCloseChannel(c:Channel):Unit {
		if (c.closed) return Unit.value;
		if (c is OutChannel) (cast c : OutChannel).flush();
		c.closed = true;
		if (c is OutChannel) outs.remove(cast c);
		var f = fds.get(c.fd);
		if (f != null && c.fd > 2) closeFd(c.fd);
		return Unit.value;
	}

	public static function camlMlSetBinaryMode(c:Channel, b:Bool):Unit {
		c.binary = b;
		return Unit.value;
	}
	public static function camlMlIsBinaryMode(c:Channel):Bool return c.binary;
	public static function camlMlSetChannelName(c:Channel, s:String):Unit {
		c.name = s;
		return Unit.value;
	}
	public static function camlMlSetBuffered(c:OutChannel, b:Bool):Unit {
		c.unbuffered = !b;
		if (!b) c.flush();
		return Unit.value;
	}
	public static function camlMlIsBuffered(c:OutChannel):Bool return !c.unbuffered;

	static var warnings = false;
	public static function camlMlEnableRuntimeWarnings(b:Bool):Unit {
		warnings = b;
		return Unit.value;
	}
	public static function camlMlRuntimeWarningsEnabled(_:Unit):Bool return warnings;

	public static function camlMlInputBigarray<A, B, C>(ic:InChannel, a:BigarrayData.Bigarray<A, B, C>, ofs:Int63, len:Int63):Int63 {
		var b = Bytes.alloc(i(len));
		var n = ic.read(b, 0, b.length);
		for (k in 0...n) a.data[i(ofs) + k] = b.get(k);
		return Int63.ofInt(n);
	}
	public static function camlMlOutputBigarray<A, B, C>(oc:OutChannel, a:BigarrayData.Bigarray<A, B, C>, ofs:Int63, len:Int63):Unit {
		for (k in 0...i(len)) oc.addByte((a.data[i(ofs) + k] : Int) & 255);
		return Unit.value;
	}
}
