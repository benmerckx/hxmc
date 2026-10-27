package hxmc.net;

import haxe.io.Error;
import hxmc.NativeNet;
import sys.net.Socket;

// poll(2) for sys.net.Socket (docs/using.md, "Sockets"): readiness as
// Socket.select gives it, without select's FD_SETSIZE. POSIX poll, Windows'
// WSAPoll; wasm32-wasi has no sockets (Custom("Function not implemented")).
class Poll {
	// events: what a descriptor is waited for
	public static inline var IN = 1; // data to read, or a connection to accept
	public static inline var PRI = 2; // urgent data
	public static inline var OUT = 4; // writable; a connect completed or failed
	// revents only, reported whether asked or not
	public static inline var ERR = 8;
	public static inline var HUP = 16;
	public static inline var NVAL = 32;

	// Waits until a socket is ready for one of its events, at most timeout
	// seconds (0: no wait, negative: no limit). Returns each socket's ready
	// events (0: none). Other threads run meanwhile; a socket closed by one
	// of them fails the call ("Bad file descriptor").
	public static function poll(sockets:Array<Socket>, events:Array<Int>, timeout:Float):Array<Int> {
		if (events.length != sockets.length) throw Custom("Poll.poll: " + sockets.length + " sockets, " + events.length + " events");
		var revents = [for (_ in sockets) 0];
		wait([for (s in sockets) socketFd(s)], events, revents, sockets.length, timeout);
		return revents;
	}

	// poll without allocating: waits for the first count entries of fds
	// (socketFd's descriptors) for their events, as poll does, and writes
	// their ready events to revents. Returns how many are ready (0: the
	// timeout passed). The arrays are the caller's, reused from call to call;
	// the system's structures are in a per-thread buffer.
	public static function wait(fds:Array<Int>, events:Array<Int>, revents:Array<Int>, count:Int, timeout:Float):Int {
		if (count < 0 || count > fds.length || count > events.length || count > revents.length) {
			var room = fds.length < events.length ? fds.length : events.length;
			throw Custom("Poll.wait: " + count + " entries, the arrays hold " + (room < revents.length ? room : revents.length));
		}
		if (count == 0) {
			if (timeout < 0) throw Custom("Poll.wait: no descriptor and no timeout");
			if (timeout > 0) Sys.sleep(timeout);
			return 0;
		}
		var r = NativeNet.poll(fds, events, revents, count, timeout);
		if (r < 0) throw Custom(NativeNet.strerror(NativeNet.errno()));
		return r;
	}

	// the descriptor of a socket, for wait (-1 once closed: never ready)
	public static inline function socketFd(s:Socket):Int
		return @:privateAccess s.fd;
}
