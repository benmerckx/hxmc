package macros.eval;

#if hl
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;

// port: HashLink host for the Eval socket natives (EvalStdLibB.hx StdSocket): the
// interface of the hxmc target's `hxmc.NativeNet` (hxmc/std), which
// stands for OCaml's Unix module, over the host's sys.net.Socket.
//
// Host differences: sockets are numbered handles into a table rather than
// file descriptors, and the host API reports failures as exceptions whose
// text replaces `Unix.error_message` (`strerror` returns the last one).
// Addresses are host-order IPv4 ints, as in `hxmc.NativeNet`.
class EvalHostNet {
	static final sockets = new Map<Int, Socket>();
	static var nextHandle = 3;
	static var lastError = "";
	static var lastBlocked = false;
	static final mutex = new sys.thread.Mutex();

	public static function errno():Int return 1;

	public static function strerror(err:Int):String return lastError;

	public static function blocked():Bool return lastBlocked;

	static function fail(e:Dynamic):Int {
		lastBlocked = Std.isOfType(e, haxe.io.Error) && Type.enumEq(e, haxe.io.Error.Blocked);
		lastError = lastBlocked ? "Resource temporarily unavailable" : Std.string(e);
		return -1;
	}

	static function register(s:Socket):Int {
		mutex.acquire();
		var h = nextHandle++;
		sockets.set(h, s);
		mutex.release();
		return h;
	}

	static function get(h:Int):Socket {
		mutex.acquire();
		var s = sockets.get(h);
		mutex.release();
		if (s == null) throw "Bad file descriptor";
		return s;
	}

	static function host(ip:Int):Host return new Host(EvalStdLibA.StdHost.int32Addr(ip));

	static function ipOf(h:Host):Int {
		var parts = h.toString().split(".").map(Std.parseInt);
		return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
	}

	public static function socket():Int {
		return try register(new Socket()) catch (e:Dynamic) fail(e);
	}

	public static function close(h:Int):Int {
		return try {
			get(h).close();
			mutex.acquire();
			sockets.remove(h);
			mutex.release();
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function accept(h:Int):Int {
		return try register(get(h).accept()) catch (e:Dynamic) fail(e);
	}

	public static function bind(h:Int, ip:Int, port:Int):Int {
		return try {
			get(h).bind(host(ip), port);
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function connect(h:Int, ip:Int, port:Int):Int {
		return try {
			get(h).connect(host(ip), port);
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function listen(h:Int, backlog:Int):Int {
		return try {
			get(h).listen(backlog);
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function sockName(h:Int, peer:Bool):Null<Array<Int>> {
		return try {
			var s = get(h);
			var a = peer ? s.peer() : s.host();
				[ipOf(a.host), a.port];
		} catch (e:Dynamic) {
			fail(e);
			null;
		}
	}

	public static function recv(h:Int, b:Bytes, pos:Int, len:Int):Int {
		return try get(h).input.readBytes(b, pos, len) catch (_:haxe.io.Eof) 0 catch (e:Dynamic) fail(e);
	}

	public static function send(h:Int, b:Bytes, pos:Int, len:Int):Int {
		return try get(h).output.writeBytes(b, pos, len) catch (e:Dynamic) fail(e);
	}

	// port: Unix.select: sets the entries of handles that are not ready to -1.
	public static function select(read:Array<Int>, write:Array<Int>, others:Array<Int>, timeout:Float):Int {
		return try {
			var r = Socket.select([for (h in read) get(h)], [for (h in write) get(h)], [for (h in others) get(h)],
				timeout < 0 ? null : timeout);
			function keep(handles:Array<Int>, ready:Array<Socket>) {
				for (i in 0...handles.length) if (ready.indexOf(get(handles[i])) < 0) handles[i] = -1;
			}
			keep(read, r.read);
			keep(write, r.write);
			keep(others, r.others);
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function setNoDelay(h:Int, b:Bool):Int {
		return try {
			get(h).setFastSend(b);
			0;
		} catch (e:Dynamic) fail(e);
	}

	// port: HashLink's socket_bind sets SO_REUSEADDR itself (on every host but Windows, as upstream's
	// `not Globals.is_windows`), and sys.net.Socket has no way to set it apart from bind.
	public static function setReuseAddr(h:Int, b:Bool):Int {
		return try {
			get(h);
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function setBroadcast(h:Int, b:Bool):Int {
		lastError = "Operation not supported";
		return -1;
	}

	public static function setTimeout(h:Int, seconds:Float):Int {
		return try {
			get(h).setTimeout(seconds);
			0;
		} catch (e:Dynamic) fail(e);
	}

	public static function shutdown(h:Int, mode:Int):Int {
		return try {
			get(h).shutdown(mode != 1, mode != 0);
			0;
		} catch (e:Dynamic) fail(e);
	}
}
#end
