package hxmc.net;

import haxe.io.Error;
import hxmc.NativeNet;
import sys.net.Socket;

// hxmc's additions to sys.net.Socket (docs/using.md, "Sockets"), as static
// extensions: `using hxmc.net.SocketTools;`.
class SocketTools {
	// After a non-blocking connect, once the socket is writable (or, on
	// Windows, in select's others set): why the connection failed, as
	// strerror words it (SO_ERROR, which this clears); null when it did not.
	public static function connectError(s:Socket):Null<String> {
		var e = NativeNet.socketError(@:privateAccess s.fd);
		if (e < 0) throw Custom(NativeNet.strerror(NativeNet.errno()));
		return e == 0 ? null : NativeNet.strerror(e);
	}

	// connectError as a throw: Custom(message) when the connection failed.
	public static function finishConnect(s:Socket):Void {
		var e = connectError(s);
		if (e != null) throw Custom(e);
	}
}
