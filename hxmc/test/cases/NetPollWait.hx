// hxmc.net.Poll.wait: poll over caller-owned arrays of descriptors, events
// and ready events, allocating nothing per call. The check: the thread's
// nursery pointer (rt_young_ptr) and the collection count do not move
// over 1000 calls.
import hxmc.net.Poll;
import hxmc.unsafe.Mem;
import sys.net.Host;
import sys.net.Socket;

class NetPollWait {
	static function main() {
		var server = new Socket();
		server.bind(new Host("127.0.0.1"), 0);
		server.listen(4);
		var client = new Socket();
		client.connect(new Host("127.0.0.1"), server.host().port);
		var conn = server.accept();

		// room for 4 entries, 2 used
		var fds = [Poll.socketFd(client), Poll.socketFd(conn), -1, -1];
		var events = [Poll.IN, Poll.IN | Poll.OUT, 0, 0];
		var revents = [7, 7, 7, 7];
		Sys.println(Poll.wait(fds, events, revents, 2, 0) + " " + revents);

		var ready = 0;
		var y0 = Mem.tlsGet("rt_young_ptr"), c0 = Mem.getI32(Mem.sym("hxmc_gc_count"), 0);
		for (i in 0...1000)
			ready += Poll.wait(fds, events, revents, 2, 0);
		var y1 = Mem.tlsGet("rt_young_ptr"), c1 = Mem.getI32(Mem.sym("hxmc_gc_count"), 0);
		Sys.println(ready + " ready, allocated " + y1.diff(y0).toInt() + " bytes, " + (c1 - c0) + " collections");

		conn.output.writeString("x");
		Sys.println(Poll.wait(fds, events, revents, 1, 5.0) + " " + revents[0]);
		Sys.println(String.fromCharCode(client.input.readByte()));
		// too few entries: a clear error
		try {
			Poll.wait(fds, events, revents, 5, 0);
			Sys.println("waited for 5 of 4");
		} catch (e:haxe.io.Error) {
			Sys.println(e);
		}
		client.close();
		conn.close();
		server.close();
	}
}
