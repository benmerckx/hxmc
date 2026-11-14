import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// A smoke test of a release build of the port (.github/workflows/build.yml's
// test job, on each target's machine; node make.mjs smoke), on its own Eval:
//   <binary> -cp hxmc/test -cp haxe/test --run Smoke <binary> [dir]
// In dir (default bin/smoke): a hello world with --interp (its Eval's host:
// the system's name, and on Windows a working directory with a drive
// letter), written as HXB and compiled to JS (run with node), then the
// natives of the bundled Eval: sys.ssl (mbedtls: the system's CA
// certificates and a TLS handshake with github.com verified with them) and
// eval.luv (libuv: a timer and a TCP echo on one loop). The extras at the end
// (processes, the file system, another target, --run) are reported, not
// fatal. Exits non-zero on a failure.
class Smoke {
	static final MAIN = '
class Main {
	static function main() {
		var a = [for (i in 0...5) i * i];
		trace("Hello from haxe-in-haxe " + a);
		var json = haxe.Json.stringify({ok: true, n: a.length});
		#if sys Sys.println(json); Sys.println("hello from " + Sys.systemName() + " in " + Sys.getCwd()); #else trace(json); #end
	}
}
';

	static final NATIVES = '
import eval.luv.*;

using eval.luv.Result;

class Natives {
	static function main() {
		// libuv: a timer, and a TCP echo between handles of the default loop
		var loop = Loop.defaultLoop();
		var log = [];
		var timer = Timer.init(loop).resolve();
		timer.start(() -> {
			log.push("timer");
			timer.close(() -> {});
		}, 10).resolve();
		var server = Tcp.init(loop).resolve();
		server.bind(SockAddr.ipv4("127.0.0.1", 0).resolve()).resolve();
		server.listen(r -> {
			r.resolve();
			var conn = Tcp.init(loop).resolve();
			server.accept(conn).resolve();
			conn.readStart(r -> switch r {
				case Ok(buf):
					log.push("echo " + buf.toString());
					conn.close(() -> server.close(() -> {}));
				case Error(e):
					throw new LuvException(e);
			});
		});
		var client = Tcp.init(loop).resolve();
		client.connect(server.getSockName().resolve(), r -> {
			r.resolve();
			client.write([Buffer.fromString("ping")], (r, _) -> {
				r.resolve();
				client.close(() -> {});
			});
		});
		loop.run(DEFAULT);
		Sys.println("libuv " + Version.string() + ": " + log.join(", "));
		if (log.indexOf("timer") < 0 || log.indexOf("echo ping") < 0) throw "libuv: missing events";

		// mbedtls: the system\'s CA certificates, a handshake verified with them
		var ca = sys.ssl.Certificate.loadDefaults();
		var n = 0;
		var c = ca;
		while (c != null) {
			if (c.commonName != null || c.subject("O") != null) n++;
			c = c.next();
		}
		Sys.println("mbedtls: " + n + " system CA certificates");
		if (n == 0) throw "mbedtls: no system CA certificates";
		var host = "github.com";
		var s = new sys.ssl.Socket();
		s.connect(new sys.net.Host(host), 443);
		s.write("HEAD / HTTP/1.0\\r\\nHost: " + host + "\\r\\n\\r\\n");
		var line = s.input.readLine();
		s.close();
		Sys.println("mbedtls: https://" + host + "/ " + line);
		if (!StringTools.startsWith(line, "HTTP/1.")) throw "mbedtls: unexpected response";
		Sys.println(\'natives {"ok":true}\');
	}
}
';

	static final EXTRA = '
class Extra {
	static function main() {
		sys.io.File.saveContent("extra.txt", "written");
		Sys.println("file: " + sys.io.File.getContent("extra.txt") + " " + sys.FileSystem.exists("extra.txt") + ", cwd " + haxe.Json.stringify(Sys.getCwd()));
		Sys.println("system: " + Sys.systemName());
		var p = new sys.io.Process("node", ["-e", "console.log(\'from node\')"]);
		Sys.println("process: " + StringTools.trim(p.stdout.readAll().toString()) + ", exit " + p.exitCode());
		Sys.println("process exit " + new sys.io.Process("node", ["-e", "process.exit(3)"]).exitCode());
		Sys.println("command exit " + Sys.command("node", ["-e", "process.exit(4)"]));
		Sys.println("shell command exit " + Sys.command("node -e process.exitCode=5"));
	}
}
';

	static var dir:String;
	static var bin:String;

	static function fail(what:String, out:String) {
		Sys.println("FAIL: " + what);
		Sys.println(out);
		Sys.exit(1);
	}

	static function run(args:Array<String>):Harness.ExecResult
		return exec([bin].concat(args), {cwd: dir, merge: true});

	// a run whose output says ok":true
	static function expect(what:String, args:Array<String>) {
		var r = run(args);
		Sys.print(r.out);
		if (r.code != 0 || r.out.indexOf('ok":true') < 0) fail(what, "");
		Sys.println("ok: " + what);
	}

	static function written(what:String, args:Array<String>, file:String) {
		var r = run(args);
		if (r.code != 0 || !FileSystem.exists('$dir/$file') || FileSystem.stat('$dir/$file').size == 0) fail(what, r.out);
		Sys.println('ok: $what (${FileSystem.stat('$dir/$file').size} bytes)');
	}

	static function main() {
		var args = Sys.args();
		if (args.length < 1) {
			Sys.println("usage: --run Smoke <binary> [dir]");
			Sys.exit(2);
		}
		bin = FileSystem.fullPath(args[0]);
		// (made first: fullPath is realpath on Unix, which fails on a missing directory)
		var d = args.length > 1 ? args[1] : "bin/smoke";
		FileSystem.createDirectory(d);
		dir = FileSystem.fullPath(d);
		File.saveContent('$dir/Main.hx', MAIN);
		File.saveContent('$dir/Natives.hx', NATIVES);
		File.saveContent('$dir/Extra.hx', EXTRA);
		Sys.print(run(["--version"]).out);
		var r = run(["-main", "Main", "--interp"]);
		Sys.print(r.out);
		if (r.code != 0 || r.out.indexOf('ok":true') < 0) fail("--interp", "");
		// (the Eval's host: Windows with a drive letter)
		var host = ~/hello from ([A-Za-z]+) in (.*)/;
		if (!host.match(r.out) || (windows && (host.matched(1) != "Windows" || !~/^[A-Z]:[\\\/]/.match(host.matched(2).trim()))))
			fail("--interp: the host", r.out);
		Sys.println("ok: --interp");
		// (Windows: the binary and the std named as Windows names them, with backslashes)
		if (windows) {
			var std = Sys.getEnv("HAXE_STD_PATH") ?? "";
			var r = exec([bin.replace("/", "\\"), "-main", "Main", "--interp"], {cwd: dir, merge: true, env: ["HAXE_STD_PATH" => std.replace("/", "\\")]});
			if (r.code != 0 || r.out.indexOf('ok":true') < 0) fail("--interp with backslashed paths", r.out);
			Sys.println("ok: --interp with backslashed paths");
		}
		written("--hxb", ["-main", "Main", "--hxb", "out.hxb"], "out.hxb");
		written("--js", ["-main", "Main", "--js", "out.js"], "out.js");
		var js = exec(["node", "out.js"], {cwd: dir, merge: true});
		if (js.code != 0 || js.out.indexOf('ok":true') < 0) fail("node out.js", js.out);
		Sys.println("ok: node out.js");
		// mbedtls and libuv, through the bundled Eval
		expect("sys.ssl and eval.luv", ["-main", "Natives", "--interp"]);
		// extras, reported but not fatal
		var fails = 0;
		for (e in [
			{name: "--interp file system and processes", args: ["-main", "Extra", "--interp"]},
			{name: "--js with --cmd", args: ["-main", "Main", "--js", "cmd.js", "--cmd", "node cmd.js"]},
			{name: "--python", args: ["-main", "Main", "--python", "out.py"]},
			{name: "--run", args: ["--run", "Main"]}
		]) {
			var r = run(e.args);
			if (r.code == 0) Sys.println("extra ok: " + e.name) else {
				Sys.println("extra FAIL: " + e.name);
				fails++;
			}
			for (l in r.out.trim().split("\n"))
				Sys.println("    " + l);
		}
		Sys.println('smoke: done ($fails extra failures)');
	}
}
