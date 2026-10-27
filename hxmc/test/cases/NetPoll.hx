// hxmc.net.Poll (poll(2), WSAPoll): readiness without select's FD_SETSIZE.
// The second part opens 1100 sockets, so the last ones are beyond
// FD_SETSIZE (1024 descriptors on Linux and macOS, 64 sockets a set on
// Windows): select fails with a clear error, poll works. Where the
// descriptor limit (ulimit -n) is lower, that part is skipped (said on
// stderr) and prints the same lines.
import hxmc.net.Poll;
import sys.net.Host;
import sys.net.Socket;

class NetPoll {
	static function pair(server:Socket):{client:Socket, conn:Socket} {
		var client = new Socket();
		client.connect(new Host("127.0.0.1"), server.host().port);
		return {client: client, conn: server.accept()};
	}

	static function main() {
		var server = new Socket();
		server.bind(new Host("127.0.0.1"), 0);
		server.listen(4);
		var p = pair(server);
		// nothing to read yet; the connection is writable
		Sys.println(Poll.poll([p.client, p.conn], [Poll.IN, Poll.IN | Poll.OUT], 0));
		p.conn.output.writeString("x");
		Sys.println(Poll.poll([p.client], [Poll.IN], 5.0));
		Sys.println(String.fromCharCode(p.client.input.readByte()));
		// a timeout: nothing ready
		Sys.println(Poll.poll([p.client], [Poll.IN], 0.05));
		p.client.close();
		p.conn.close();
		try {
			Poll.poll([], [], -1);
			Sys.println("waited forever");
		} catch (e:haxe.io.Error) {
			Sys.println("no socket and no timeout: " + e.match(Custom(_)));
		}

		var fillers = [];
		var opened = try {
			for (i in 0...1100)
				fillers.push(new Socket());
			true;
		} catch (e:Dynamic) false;
		if (!opened) {
			for (s in fillers)
				s.close();
			fillers = [];
			Sys.stderr().writeString("NetPoll: fewer than 1100 descriptors, the FD_SETSIZE part skipped\n");
		}
		var q = pair(server);
		var all = fillers.concat([q.client]);
		var events = [for (s in all) s == q.client ? Poll.IN : 0];
		if (opened) {
			try {
				Socket.select(all, null, null, 0);
				Sys.println("select took them all");
			} catch (e:haxe.io.Error) {
				switch e {
					case Custom(m): Sys.println("select: " + ((m : String).indexOf("FD_SETSIZE") >= 0));
					case _: Sys.println("select: " + e);
				}
			}
		} else Sys.println("select: true");
		var r = Poll.poll(all, events, 0);
		Sys.println(r[r.length - 1]);
		q.conn.output.writeString("y");
		r = Poll.poll(all, events, 5.0);
		Sys.println(r[r.length - 1] + " " + String.fromCharCode(q.client.input.readByte()));
		for (s in fillers)
			s.close();
		q.client.close();
		q.conn.close();
		server.close();
	}
}
