// hxmc: haxe/upstream/std/eval/_std/sys/net/Socket.hx: TCP sockets over hxmc.NativeNet
// (rt_net.c, file descriptors). Non-blocking sockets throw
// haxe.io.Error.Blocked when not ready; their connect returns while the
// connection is in progress, as on HashLink, hxcpp and Neko
// (hxmc.net.SocketTools.connectError tells how it ended).

package sys.net;

import haxe.io.Bytes;
import haxe.io.Error;
import hxmc.NativeNet;

private class SocketOutput extends haxe.io.Output {
	var socket:Socket;

	public function new(socket:Socket) {
		this.socket = socket;
	}

	override public function writeByte(c:Int) {
		var b = Bytes.alloc(1);
		b.set(0, c);
		writeBytes(b, 0, 1);
	}

	override public function writeBytes(buf:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length) throw OutsideBounds;
		var r = NativeNet.send(@:privateAccess socket.fd, buf, pos, len);
		if (r < 0) {
			if (NativeNet.blocked()) throw Blocked;
			throw Custom(NativeNet.strerror(NativeNet.errno()));
		}
		return r;
	}

	override public function close() {
		super.close();
		socket.close();
	}
}

private class SocketInput extends haxe.io.Input {
	var socket:Socket;

	public function new(socket:Socket) {
		this.socket = socket;
	}

	override public function readByte():Int {
		var b = Bytes.alloc(1);
		readBytes(b, 0, 1);
		return b.get(0);
	}

	override public function readBytes(buf:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length) throw OutsideBounds;
		var r = NativeNet.recv(@:privateAccess socket.fd, buf, pos, len);
		if (r < 0) {
			if (NativeNet.blocked()) throw Blocked;
			throw Custom(NativeNet.strerror(NativeNet.errno()));
		}
		if (r == 0) throw new haxe.io.Eof();
		return r;
	}

	override public function close() {
		super.close();
		socket.close();
	}
}

class Socket {
	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	var fd:Int;
	var nonBlocking:Bool;

	public function new():Void {
		init(check(NativeNet.socket()));
	}

	function init(fd:Int) {
		this.fd = fd;
		input = new SocketInput(this);
		output = new SocketOutput(this);
	}

	static function check(r:Int):Int {
		if (r < 0) {
			if (NativeNet.blocked()) throw Blocked;
			throw Custom(NativeNet.strerror(NativeNet.errno()));
		}
		return r;
	}

	public function close():Void {
		if (fd >= 0) {
			NativeNet.close(fd);
			fd = -1;
		}
	}

	public function read():String {
		return input.readAll().toString();
	}

	public function write(content:String):Void {
		output.writeString(content);
	}

	public function connect(host:Host, port:Int):Void {
		// hxmc: a non-blocking socket's connection in progress is no error (as
		// HashLink's, hxcpp's and Neko's socket_connect): the socket becomes
		// writable once it completes or fails
		if (NativeNet.connect(fd, host.ip, port) < 0 && !(nonBlocking && NativeNet.inProgress())) check(-1);
	}

	public function listen(connections:Int):Void {
		check(NativeNet.listen(fd, connections));
	}

	public function shutdown(read:Bool, write:Bool):Void {
		if (read || write) check(NativeNet.shutdown(fd, read && write ? 2 : read ? 0 : 1));
	}

	public function bind(host:Host, port:Int):Void {
		// hxmc: as HashLink's socket_bind: a server restarted on its port does not
		// wait for the previous connections' TIME_WAIT (the compilation server
		// relies on it, see src/compiler/server/Server.hx initWaitSocket)
		NativeNet.setReuseAddr(fd, true);
		check(NativeNet.bind(fd, host.ip, port));
	}

	public function accept():Socket {
		var s:Socket = Type.createEmptyInstance(Socket);
		s.init(check(NativeNet.accept(fd)));
		return s;
	}

	function address(peer:Bool):{host:Host, port:Int} {
		var a = NativeNet.sockName(fd, peer);
		if (a == null) throw Custom(NativeNet.strerror(NativeNet.errno()));
		var h:Host = Type.createEmptyInstance(Host);
		@:privateAccess h.ip = a[0];
		@:privateAccess h.host = h.toString();
		return {host: h, port: a[1]};
	}

	public function peer():{host:Host, port:Int} {
		return address(true);
	}

	public function host():{host:Host, port:Int} {
		return address(false);
	}

	public function setTimeout(timeout:Float):Void {
		check(NativeNet.setTimeout(fd, timeout));
	}

	public function waitForRead():Void {
		select([this], null, null, null);
	}

	public function setBlocking(b:Bool):Void {
		check(NativeNet.setBlocking(fd, b));
		nonBlocking = !b;
	}

	public function setFastSend(b:Bool):Void {
		check(NativeNet.setNoDelay(fd, b));
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		if (read == null) read = [];
		if (write == null) write = [];
		if (others == null) others = [];
		var r = [for (s in read) s.fd], w = [for (s in write) s.fd], o = [for (s in others) s.fd];
		// hxmc: select(2) cannot go beyond FD_SETSIZE: a clear error there
		var n = NativeNet.select(r, w, o, timeout == null ? -1.0 : timeout);
		if (n == -2) {
			var limit = NativeNet.selectLimit();
			throw Custom("Socket.select: beyond FD_SETSIZE (" + limit + (limit == 64 ? " sockets a set" : " descriptors")
				+ "); hxmc.net.Poll has no such limit");
		}
		check(n);
		// NativeNet.select sets the descriptors that are not ready to -1
		return {
			read: [for (i in 0...read.length) if (r[i] >= 0) read[i]],
			write: [for (i in 0...write.length) if (w[i] >= 0) write[i]],
			others: [for (i in 0...others.length) if (o[i] >= 0) others[i]]
		};
	}
}
