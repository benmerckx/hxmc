// A non-blocking connect on the loopback interface. As on HashLink, hxcpp
// and Neko, a connection still in progress is no error: connect returns,
// and the socket is reported writable (or, on Windows, in the others set)
// once the connection completes or fails; hxmc.net.SocketTools reads why
// it failed (SO_ERROR): the error a blocking connect throws.
import sys.net.Host;
import sys.net.Socket;

using hxmc.net.SocketTools;

class NetConnectAsync {
	static function connect(s:Socket, port:Int):String {
		return try {
			s.connect(new Host("127.0.0.1"), port);
			"connect returned";
		} catch (e:Dynamic) {
			"connect threw " + Std.string(e);
		}
	}

	// a connection completed or failed: writable, or in the others set
	static function settled(s:Socket):Bool {
		var r = Socket.select(null, [s], [s], 10.0);
		return r.write.length + r.others.length > 0;
	}

	static function main() {
		var server = new Socket();
		server.bind(new Host("127.0.0.1"), 0);
		server.listen(4);
		var port = server.host().port;

		var client = new Socket();
		client.setBlocking(false);
		Sys.println(connect(client, port));
		Sys.println(settled(client));
		Sys.println(client.connectError());
		client.finishConnect();
		var conn = server.accept();
		client.output.writeString("hi\n");
		Sys.println(conn.input.readLine());
		conn.close();
		client.close();

		// a port nobody listens on
		var probe = new Socket();
		probe.bind(new Host("127.0.0.1"), 0);
		var closed = probe.host().port;
		probe.close();
		var blocking = new Socket();
		var expected = try {
			blocking.connect(new Host("127.0.0.1"), closed);
			null;
		} catch (e:haxe.io.Error) e;
		blocking.close();
		Sys.println(expected != null);
		var refused = new Socket();
		refused.setBlocking(false);
		Sys.println(connect(refused, closed));
		Sys.println(settled(refused));
		try {
			refused.finishConnect();
			Sys.println("connected to a closed port");
		} catch (e:haxe.io.Error) {
			Sys.println("as a blocking connect: " + Type.enumEq(e, expected));
		}
		refused.close();
		server.close();
	}
}
