import compiler.CompilerInstance;
import compiler.server.Server;
import js.node.Buffer;
import js.node.Net;

// `haxe --wait [host:]port` on Node.js (bin/node/haxe-server.cjs, haxe/nodejs/server.hxml):
// the transport is Node's (net, the event loop); the compiler's state and the lifecycle
// of each request are CompilerInstance's, and the protocol (decoding a request,
// encoding its output) Server's, as for the native server. Requests run one at a time
// on the event loop, the server's background tasks between them.
// Not supported: the client's stdin after the request (a program reading it sees it
// closed), and threads (the stand-ins in haxe/nodejs/sys throw).
class NodeServer {
	static function main() {
		final args = Sys.args();
		if (args.length == 0) {
			Sys.stderr().writeString("Usage: node haxe-server.cjs [host:]port [-v]\n");
			Sys.exit(1);
		}
		final hp = args[0].split(":");
		final port = Std.parseInt(hp.pop());
		final host = hp.length > 0 ? hp.join(":") : "127.0.0.1";
		final instance = new CompilerInstance(args.contains("-v"));
		var scheduled = false;
		function background() {
			if (scheduled || !instance.hasTask()) return;
			scheduled = true;
			js.Node.setImmediate(() -> {
				scheduled = false;
				instance.runTask();
				background();
			});
		}
		Net.createServer((socket) -> {
			final chunks:Array<Buffer> = [];
			var received = false;
			socket.on("error", (_) -> {}); // the client went away: its output is dropped
			socket.on("data", (b:Buffer) -> {
				if (received) return;
				final end = b.indexOf(0);
				if (end < 0) {
					chunks.push(b);
					return;
				}
				chunks.push(b.slice(0, end));
				received = true;
				final stdin = Server.makeClosedStdin();
				final conn:ServerConnection = {
					read: () -> null,
					write: (s:String) -> socket.write(s),
					close: () -> socket.end(),
					getStdin: () -> stdin,
				};
				final request = Server.parseRequest(Buffer.concat(chunks).toString(), conn);
				switch instance.request(request, Server.createRequestIo(request), conn.close) {
					case Oom: Sys.exit(-1);
					case _:
				}
				background();
			});
		}).listen(port, host, () -> Sys.println('Waiting on $host:$port'));
	}
}
