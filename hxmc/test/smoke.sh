#!/bin/sh
# A smoke test of a release build of the port (.github/workflows/build.yml's
# test job, on each target's machine): runs a hello world with --interp, writes HXB and compiles it
# to JS (and runs that with node when available), then checks the natives of
# the bundled Eval: sys.ssl (mbedtls: the system's CA certificates and a TLS
# handshake verified with them, with SMOKE_TLS_HOST, default github.com; empty
# skips the handshake) and eval.luv (libuv: a timer and a TCP echo on one loop).
#
#   HAXE_STD_PATH=<std> sh hxmc/test/smoke.sh <binary>
#
# SMOKE_NATIVES=0 skips the sys.ssl and eval.luv checks (builds without
# mbedtls and libuv); SMOKE_STRICT=1 makes the extras at the end fatal.
set -eu
BIN=$1
case "$BIN" in /*|[A-Za-z]:*) ;; *) BIN=$PWD/$BIN ;; esac
export SMOKE_TLS_HOST=${SMOKE_TLS_HOST-github.com}
W=${SMOKE_DIR:-$(mktemp -d)}
mkdir -p "$W"
cd "$W"
cat > Main.hx <<'EOF'
class Main {
	static function main() {
		var a = [for (i in 0...5) i * i];
		trace("Hello from haxe-in-haxe " + a);
		var json = haxe.Json.stringify({ok: true, n: a.length});
		#if sys Sys.println(json); #else trace(json); #end
	}
}
EOF
expect() {
	if ! grep -q 'ok":true' "$1"; then
		echo "FAIL: $2"
		cat "$1"
		exit 1
	fi
	echo "ok: $2"
}
"$BIN" --version
"$BIN" -main Main --interp > interp.txt 2>&1 || { cat interp.txt; exit 1; }
cat interp.txt
expect interp.txt "--interp"
"$BIN" -main Main --hxb out.hxb
test -s out.hxb
echo "ok: --hxb ($(wc -c < out.hxb) bytes)"
"$BIN" -main Main --js out.js
test -s out.js
echo "ok: --js ($(wc -c < out.js) bytes)"
if command -v node > /dev/null 2>&1; then
	node out.js > js.txt 2>&1 || { cat js.txt; exit 1; }
	expect js.txt "node out.js"
fi
# mbedtls and libuv, through the bundled Eval
if [ "${SMOKE_NATIVES:-1}" != 0 ]; then
	cat > Natives.hx <<'EOF'
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

		// mbedtls: the system's CA certificates, a handshake verified with them
		var ca = sys.ssl.Certificate.loadDefaults();
		var n = 0;
		var c = ca;
		while (c != null) {
			if (c.commonName != null || c.subject("O") != null) n++;
			c = c.next();
		}
		Sys.println("mbedtls: " + n + " system CA certificates");
		if (n == 0) throw "mbedtls: no system CA certificates";
		var host = Sys.getEnv("SMOKE_TLS_HOST");
		if (host != null && host != "") {
			var s = new sys.ssl.Socket();
			s.connect(new sys.net.Host(host), 443);
			s.write("HEAD / HTTP/1.0\r\nHost: " + host + "\r\n\r\n");
			var line = s.input.readLine();
			s.close();
			Sys.println("mbedtls: https://" + host + "/ " + line);
			if (!StringTools.startsWith(line, "HTTP/1.")) throw "mbedtls: unexpected response";
		}
		Sys.println('natives {"ok":true}');
	}
}
EOF
	"$BIN" -main Natives --interp > natives.txt 2>&1 || { cat natives.txt; echo "FAIL: sys.ssl and eval.luv"; exit 1; }
	cat natives.txt
	expect natives.txt "sys.ssl and eval.luv"
fi
# extras, reported but not fatal (SMOKE_STRICT=1 makes them fatal): processes,
# the file system, another target, --run
cat > Extra.hx <<'EOF'
class Extra {
	static function main() {
		sys.io.File.saveContent("extra.txt", "written");
		Sys.println("file: " + sys.io.File.getContent("extra.txt") + " " + sys.FileSystem.exists("extra.txt") + ", cwd " + haxe.Json.stringify(Sys.getCwd()));
		Sys.println("system: " + Sys.systemName());
		var p = new sys.io.Process("node", ["-e", "console.log('from node')"]);
		Sys.println("process: " + StringTools.trim(p.stdout.readAll().toString()) + ", exit " + p.exitCode());
		Sys.println("process exit " + new sys.io.Process("node", ["-e", "process.exit(3)"]).exitCode());
		Sys.println("command exit " + Sys.command("node", ["-e", "process.exit(4)"]));
		Sys.println("shell command exit " + Sys.command("node -e process.exitCode=5"));
	}
}
EOF
fails=0
extra() {
	name=$1
	shift
	if "$@" > extra.log 2>&1; then
		echo "extra ok: $name"
	else
		echo "extra FAIL: $name"
		fails=$((fails + 1))
	fi
	sed 's/^/    /' extra.log
}
extra "--interp file system and processes" "$BIN" -main Extra --interp
extra "--js with --cmd" "$BIN" -main Main --js cmd.js --cmd "node cmd.js"
extra "--python" "$BIN" -main Main --python out.py
extra "--run" "$BIN" --run Main
echo "smoke: done ($fails extra failures)"
if [ "$fails" -gt 0 ] && [ -n "${SMOKE_STRICT:-}" ]; then exit 1; fi
exit 0
