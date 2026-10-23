import Harness.*;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Compilation-server conformance of the port:
//   <haxe> -cp haxe/test --run Server [-j N] [--rounds N] [--hxb-cache] [--fresh]
//       [--scenario cases|edit|misc|server-connect|all] [--cases FILE] [--no-hxb] [--summary <file>] [name-substring ...]
// Starts the reference (HAXE_REFERENCE) and the port (HAXE_IN_HAXE_PORT) as
// compilation servers (`--wait <port>`) and sends both the same requests
// through `--connect` (each compiler's client to its own server). For each
// request the exit code and the client's stdout/stderr (scratch paths
// normalized) must agree, and the HXB archives must conform.
// - cases: every case of the list (default haxe/test/conformance-cases.txt) is
//   compiled --rounds times in a row on the same servers (later rounds reuse
//   the cache);
// - edit: a small project is compiled, edited, extended, broken, fixed,
//   shrunk and touched; the verbose server logs (`-v`) must agree line by line
//   (timing lines dropped);
// - misc: program output under --interp, stdin forwarding, --cmd, macro
//   output, errors, --version and --next through the server;
// - server-connect: the compilers connect to this script (--server-connect) and
//   answer length-prefixed requests.
// --no-hxb compares the requests' exit codes and outputs only, not the archives:
// for a port whose macro context is typed for another platform (-D
// hxmc.mir-macros), whose archive then lays the modules out otherwise.
// --hxb-cache keeps the default HXB module cache (by default every request
// adds -D disable-hxb-cache); --fresh restarts the servers for every case.
class Server {
	static final GENERATED = "bin/test/server";
	static final COMMON = ["-D", "disable-parallelism", "--interp", "--no-output"];
	public static var gen:String;

	static function freePort():Int {
		var s = new sys.net.Socket();
		s.bind(new sys.net.Host("127.0.0.1"), 0);
		var p = s.host().port;
		s.close();
		return p;
	}

	// whether a TCP socket listens on the port (Linux /proc: connecting to probe
	// would send an empty request, which makes a server stop)
	static function listening(port:Int):Bool {
		if (!FileSystem.exists("/proc/net/tcp")) {
			Sys.sleep(2);
			return true;
		}
		var hex = StringTools.hex(port, 4).toUpperCase();
		for (line in File.getContent("/proc/net/tcp").split("\n").slice(1)) {
			var f = line.split(" ").filter(s -> s != "");
			if (f.length > 3 && f[1].endsWith(":" + hex) && f[3] == "0A") return true;
		}
		return false;
	}

	// whether a child process still runs (Eval has no non-blocking exitCode():
	// /proc, where an exited child is a zombie until it is waited for)
	public static function alive(p:sys.io.Process):Bool {
		var stat = '/proc/${p.getPid()}/stat';
		if (!FileSystem.exists(stat)) return exec(["kill", "-0", Std.string(p.getPid())]).code == 0;
		var t = readText(stat);
		var close = t.lastIndexOf(")");
		return close >= 0 && t.charAt(close + 2) != "Z";
	}

	public static function startServer(name:String, cmd:Array<String>, log:String, verbose = false):ServerProc {
		var port = freePort();
		var args = cmd.concat(verbose ? ["-v"] : []).concat(["--wait", Std.string(port)]);
		var p = new sys.io.Process("/bin/sh", ["-c", 'exec "$$@" >' + quote(log) + ' 2>&1 </dev/null', "sh"].concat(args));
		var deadline = now() + 30;
		while (now() < deadline) {
			if (!alive(p)) fail('$name server exited early, see $log');
			if (listening(port)) return {name: name, port: port, proc: p, log: log};
			Sys.sleep(0.1);
		}
		return fail('$name server did not start');
	}

	public static function stopServer(s:ServerProc) {
		exec(["kill", Std.string(s.proc.getPid())]);
		var deadline = now() + 10;
		while (alive(s.proc) && now() < deadline) Sys.sleep(0.05);
		if (alive(s.proc)) s.proc.kill();
		s.proc.exitCode();
		s.proc.close();
	}

	public static function client(cmd:Array<String>, port:Int, args:Array<String>, cwd:String, ?input:String, timeout = 900):ServerOut {
		var stdin = null;
		if (input != null) {
			stdin = tempName() + ".in";
			File.saveContent(stdin, input);
		}
		var r = exec(cmd.concat(["--connect", Std.string(port)]).concat(args), {cwd: cwd, timeout: timeout, stdin: stdin});
		if (stdin != null) FileSystem.deleteFile(stdin);
		return {code: r.timedOut ? "timeout" : Std.string(r.code), out: r.out, err: r.err};
	}

	static function normalize(text:String, outDir:String):String
		return ~/\b(ref|port)([0-9]*)\.hxb/g.replace(text.replace(outDir, "<OUT>"), "X$2.hxb");

	static var noHxb = false;

	static function compareOutputs(ref:ServerOut, port:ServerOut, refHxb:Null<String>, portHxb:Null<String>, outDir:String):Null<String> {
		if (ref.code != port.code) return 'exit code differs (reference ${ref.code}, port ${port.code}): ' + (port.err != "" ? port.err : ref.err).trim().substr(0, 300);
		if (normalize(ref.out, outDir) != normalize(port.out, outDir)) return 'stdout differs: reference ${haxe.Json.stringify(ref.out.substr(0, 200))}, port ${haxe.Json.stringify(port.out.substr(0, 200))}';
		if (normalize(ref.err, outDir) != normalize(port.err, outDir)) return 'stderr differs: reference ${haxe.Json.stringify(ref.err.substr(0, 300))}, port ${haxe.Json.stringify(port.err.substr(0, 300))}';
		if (ref.code == "0" && refHxb != null && FileSystem.exists(refHxb) && !noHxb) {
			if (!FileSystem.exists(portHxb)) return "port wrote no archive";
			return compareHxb(refHxb, portHxb);
		}
		return null;
	}

	static function members(hxb:String) return readZip(hxb).names.length;

	static function scenarioCases(o:Harness.Args, cases:Array<Conformance.ConfCase>, ref:Array<String>, port:Array<String>, extra:Array<String>):Array<ServerRes> {
		var jobs = o.int("-j", 1), rounds = o.int("--rounds", 2), fresh = o.has("--fresh");
		var servers = [for (k in 0...jobs) {r: startServer("reference", ref, '$gen/reference-$k.log'), p: startServer("port", port, '$gen/port-$k.log')}];
		var results = [];
		var m = new sys.thread.Mutex();
		parallel([for (k in 0...jobs) k], jobs, k -> {
			var out = [];
			for (i in 0...cases.length) {
				if (i % jobs != k) continue;
				var c = cases[i];
				var d = '$gen/${c.name}';
				rmrf(d);
				mkdirs(d);
				if (fresh) {
					stopServer(servers[k].r);
					stopServer(servers[k].p);
					servers[k] = {r: startServer("reference", ref, '$gen/reference-$k.log'), p: startServer("port", port, '$gen/port-$k.log')};
				}
				for (rnd in 1...rounds + 1) {
					var refHxb = '$d/ref$rnd.hxb', portHxb = '$d/port$rnd.hxb';
					function inv(hxb:String) return c.hxml ? ["--hxb", hxb, "-D", "disable-parallelism", "--no-output"].concat(extra).concat(c.args) : COMMON.concat(extra).concat(c.args).concat(["--hxb", hxb]);
					var t0 = now();
					var a = client(ref, servers[k].r.port, inv(refHxb), c.cwd);
					var b = client(port, servers[k].p.port, inv(portHxb), c.cwd);
					var detail = compareOutputs(a, b, refHxb, portHxb, d);
					var status = detail == null ? "PASS" : "FAIL";
					if (detail == null) detail = a.code != "0" ? "both reject" : members(refHxb) + " members identical";
					var res = {name: '${c.name}#$rnd', status: status, detail: detail, seconds: now() - t0};
					m.acquire();
					Sys.println(pad(res.status, 6) + " " + pad(res.name, 44) + " " + fixed(res.seconds).lpad(" ", 6) + "s  " + res.detail);
					m.release();
					out.push(res);
				}
			}
			out;
		}, (_, out) -> for (r in out) results.push(r));
		for (s in servers) {
			stopServer(s.r);
			stopServer(s.p);
		}
		return results;
	}

	static final EDIT_MAIN = "class Main {\n\tstatic function main() {\n\t\ttrace(Helper.value());\n\t\tvar o = new Other();\n\t\ttrace(o.name());\n\t}\n}\n";
	static final EDIT_HELPER = "class Helper {\n\tpublic static function value() return 1;\n}\n";
	static final EDIT_HELPER2 = "class Helper {\n\tpublic static function value() return \"changed \" + Added.x;\n}\n";
	static final EDIT_OTHER = "class Other {\n\tpublic function new() {}\n\tpublic function name() return \"other\";\n}\n";
	static final EDIT_ADDED = "class Added {\n\tpublic static var x = 42;\n}\n";
	static final EDIT_BROKEN = "class Helper {\n\tpublic static function value() return 1 +;\n}\n";

	static function scenarioEdit(ref:Array<String>, port:Array<String>, extra:Array<String>):Array<ServerRes> {
		var results = [];
		var r = startServer("reference", ref, '$gen/edit-reference.log', true);
		var p = startServer("port", port, '$gen/edit-port.log', true);
		var proj = '$gen/edit-project';
		rmrf(proj);
		for (d in ["src", "out-ref", "out-port"]) mkdirs('$proj/$d');
		function write(name:String, text:String) File.saveContent('$proj/src/$name', text);
		write("Main.hx", EDIT_MAIN);
		write("Helper.hx", EDIT_HELPER);
		write("Other.hx", EDIT_OTHER);
		var steps:Array<{name:String, action:Null<Void->Void>}> = [
			{name: "initial", action: null},
			{name: "unchanged", action: null},
			{name: "edit-helper", action: () -> {write("Added.hx", EDIT_ADDED); write("Helper.hx", EDIT_HELPER2);}},
			{name: "unchanged-after-edit", action: null},
			{name: "syntax-error", action: () -> write("Helper.hx", EDIT_BROKEN)},
			{name: "fixed", action: () -> write("Helper.hx", EDIT_HELPER2)},
			{name: "remove-file", action: () -> {FileSystem.deleteFile('$proj/src/Added.hx'); write("Helper.hx", EDIT_HELPER);}},
			{name: "touch-only", action: () -> exec(["touch", '$proj/src/Other.hx'])},
		];
		for (s in steps) {
			if (s.action != null) {
				Sys.sleep(1.1); // file times have one-second resolution on some hosts
				s.action();
			}
			var outs = new Map<String, {o:ServerOut, hxb:String}>();
			for (x in [{who: "ref", cmd: ref, srv: r}, {who: "port", cmd: port, srv: p}]) {
				var hxb = '$proj/out-${x.who}/${s.name}.hxb';
				var o = client(x.cmd, x.srv.port, COMMON.concat(extra).concat(["-cp", "src", "--main", "Main", "--hxb", hxb]), proj);
				outs[x.who] = {o: {code: o.code, out: o.out.replace("out-" + x.who, "out-X"), err: o.err.replace("out-" + x.who, "out-X")}, hxb: hxb};
			}
			var detail = compareOutputs(outs["ref"].o, outs["port"].o, outs["ref"].hxb, outs["port"].hxb, proj);
			var status = detail == null ? "PASS" : "FAIL";
			if (detail == null) detail = outs["ref"].o.code != "0" ? "both reject" : members(outs["ref"].hxb) + " members identical";
			Sys.println(pad(status, 6) + " " + pad("edit:" + s.name, 44) + " " + detail);
			results.push({name: "edit:" + s.name, status: status, detail: detail, seconds: 0.0});
		}
		stopServer(r);
		stopServer(p);
		// the server logs must agree apart from timing, socket chunking and ports
		function logLines(path:String, who:String):Array<String> {
			var lines = [];
			for (line in readText(path).split("\n")) {
				line = line.replace("out-" + who, "out-X");
				if (line == "" || Lambda.exists(["Time spent", "SIGNAL", "Waiting for data", "Reading ", "connect_arg:", ".init"], p -> line.startsWith(p))) continue;
				if (~/^\s*\S+\(.*:[0-9]+\)$/.match(line)) continue; // host stack trace on termination
				lines.push(line);
			}
			return lines;
		}
		var a = logLines('$gen/edit-reference.log', "ref"), b = logLines('$gen/edit-port.log', "port");
		var same = a.join("\n") == b.join("\n");
		var detail = 'server logs agree (${a.length} lines)';
		if (!same) {
			var diff = lineDiff(a.join("\n"), b.join("\n"), 200);
			File.saveContent('$gen/edit-log.diff', diff.join("\n") + "\n");
			detail = 'server logs differ, see $GENERATED/edit-log.diff';
		}
		Sys.println(pad(same ? "PASS" : "FAIL", 6) + " " + pad("edit:server-log", 44) + " " + detail);
		results.push({name: "edit:server-log", status: same ? "PASS" : "FAIL", detail: detail, seconds: 0.0});
		return results;
	}

	static final MISC_MAIN = "class Main {\n\t@:deprecated(\"use other\") static function old() return 1;\n\tstatic function main() {\n\t\ttrace(\"hello \" + old());\n\t\tvar line = try Sys.stdin().readLine() catch (e:haxe.io.Eof) \"<eof>\";\n\t\tSys.println(\"stdin: \" + line);\n\t\tSys.stderr().writeString(\"to stderr\\n\");\n\t}\n}\n";
	static final MISC_BROKEN = "class Broken {\n\tstatic function main() {\n\t\tvar x:Int = \"not an int\";\n\t}\n}\n";
	static final MISC_REQUESTS:Array<{name:String, args:Array<String>, input:String}> = [
		{name: "interp-run", args: ["-cp", "src", "--main", "Main", "--interp"], input: ""},
		{name: "interp-stdin", args: ["-cp", "src", "--main", "Main", "--interp"], input: "forwarded line\nsecond\n"},
		{name: "cmd", args: ["-cp", "src", "--main", "Main", "--interp", "--cmd", "echo from-cmd", "--cmd", "sh -c 'cat; echo err >&2; exit 0'"], input: "cmd stdin\n"},
		{name: "cmd-fails", args: ["-cp", "src", "--main", "Main", "--interp", "--cmd", "sh -c 'exit 3'"], input: ""},
		{name: "macro-print", args: ["-cp", "src", "--main", "Main", "--no-output", "--macro", "Sys.println('from macro')"], input: ""},
		{name: "type-error", args: ["-cp", "src", "--main", "Broken", "--interp", "--no-output"], input: ""},
		{name: "missing-class", args: ["-cp", "src", "--main", "Nope", "--interp", "--no-output"], input: ""},
		{name: "version", args: ["--version"], input: ""},
		{name: "next", args: ["-cp", "src", "--main", "Main", "--interp", "--no-output", "--next", "-cp", "src", "--main", "Broken", "--interp", "--no-output"], input: ""},
		{name: "interp-run-again", args: ["-cp", "src", "--main", "Main", "--interp"], input: ""},
	];

	static function miscProject():String {
		var proj = '$gen/misc-project';
		mkdirs('$proj/src');
		File.saveContent('$proj/src/Main.hx', MISC_MAIN);
		File.saveContent('$proj/src/Broken.hx', MISC_BROKEN);
		return proj;
	}

	static function scenarioMisc(ref:Array<String>, port:Array<String>, extra:Array<String>):Array<ServerRes> {
		var results = [];
		rmrf('$gen/misc-project');
		var proj = miscProject();
		var r = startServer("reference", ref, '$gen/misc-reference.log');
		var p = startServer("port", port, '$gen/misc-port.log');
		for (q in MISC_REQUESTS) {
			var args = ["-D", "disable-parallelism"].concat(extra).concat(q.args);
			var a = client(ref, r.port, args, proj, q.input, 300);
			var b = client(port, p.port, args, proj, q.input, 300);
			var detail = compareOutputs(a, b, null, null, proj);
			var status = detail == null ? "PASS" : "FAIL";
			if (detail == null) detail = 'exit ${a.code}, ${a.out.length} bytes stdout, ${a.err.length} bytes stderr identical';
			Sys.println(pad(status, 6) + " " + pad("misc:" + q.name, 44) + " " + detail);
			results.push({name: "misc:" + q.name, status: status, detail: detail, seconds: 0.0});
		}
		stopServer(r);
		stopServer(p);
		return results;
	}

	static function scenarioServerConnect(ref:Array<String>, port:Array<String>, extra:Array<String>):Array<ServerRes> {
		var results = [];
		var proj = FileSystem.fullPath(miscProject());
		var requests = [
			["--cwd", proj, "-D", "disable-parallelism"].concat(extra).concat(["-cp", "src", "--main", "Main", "--interp"]),
			["--cwd", proj, "-D", "disable-parallelism"].concat(extra).concat(["-cp", "src", "--main", "Broken", "--interp", "--no-output"]),
			["--cwd", proj, "-D", "disable-parallelism"].concat(extra).concat(["-cp", "src", "--main", "Main", "--interp"]),
		];
		var responses = new Map<String, Array<String>>();
		for (x in [{who: "ref", cmd: ref}, {who: "port", cmd: port}]) {
			var listener = new sys.net.Socket();
			listener.bind(new sys.net.Host("127.0.0.1"), 0);
			listener.listen(1);
			var lp = listener.host().port;
			var log = '$gen/server-connect-${x.who}.log';
			var proc = new sys.io.Process("/bin/sh", ["-c", 'exec "$$@" >' + quote(log) + ' 2>&1 </dev/null', "sh"].concat(x.cmd).concat(["--server-connect", '127.0.0.1:$lp']));
			var out = [];
			try {
				listener.setTimeout(60);
				var conn = listener.accept();
				conn.setTimeout(300);
				for (req in requests) {
					var payload = Bytes.ofString(req.join("\n"));
					var len = Bytes.alloc(4);
					len.setInt32(0, payload.length);
					conn.output.write(len);
					conn.output.write(payload);
					conn.output.flush();
					var n = conn.input.read(4).getInt32(0);
					out.push(conn.input.read(n).toString());
				}
				conn.close();
				var deadline = now() + 60;
				while (alive(proc) && now() < deadline) Sys.sleep(0.05);
				out.push("exit " + proc.exitCode());
			} catch (e:Dynamic) {
				out.push("error: " + Std.string(e));
				proc.kill();
			}
			listener.close();
			responses[x.who] = out;
		}
		var a = responses["ref"], b = responses["port"];
		for (i in 0...(a.length < b.length ? a.length : b.length)) {
			var same = a[i] == b[i];
			var detail = same ? '${a[i].length} bytes identical' : 'reference ${haxe.Json.stringify(a[i].substr(0, 300))}, port ${haxe.Json.stringify(b[i].substr(0, 300))}';
			var name = 'server-connect:${i + 1}';
			Sys.println(pad(same ? "PASS" : "FAIL", 6) + " " + pad(name, 44) + " " + detail);
			results.push({name: name, status: same ? "PASS" : "FAIL", detail: detail, seconds: 0.0});
		}
		return results;
	}

	static function main() {
		var o = parseArgs(Sys.args(), ["-j", "--rounds", "--scenario", "--cases", "--summary"]);
		var reference = Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe";
		if (!FileSystem.exists(reference)) fail("Server: no reference compiler at " + reference);
		var ref = [FileSystem.fullPath(reference)];
		var port = shellSplit(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		if (FileSystem.exists(port[0])) port[0] = FileSystem.fullPath(port[0]);
		var std = root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		Sys.putEnv("HAXE_IN_HAXE_STD_PATH", std);
		mkdirs(GENERATED);
		gen = FileSystem.fullPath(GENERATED);
		var extra = o.has("--hxb-cache") ? [] : ["-D", "disable-hxb-cache"];
		noHxb = o.has("--no-hxb");
		var scenario = o.get("--scenario", "all");
		var results = [];
		if (scenario == "cases" || scenario == "all") {
			var cases = Conformance.parseCases(o.get("--cases", "haxe/test/conformance-cases.txt"));
			cases = [for (c in cases) if (o.rest.length == 0 || Lambda.exists(o.rest, f -> c.name.contains(f))) c];
			results = results.concat(scenarioCases(o, cases, ref, port, extra));
		}
		if (scenario == "edit" || scenario == "all") results = results.concat(scenarioEdit(ref, port, extra));
		if (scenario == "misc" || scenario == "all") results = results.concat(scenarioMisc(ref, port, extra));
		if (scenario == "server-connect" || scenario == "all") results = results.concat(scenarioServerConnect(ref, port, extra));
		var counts = new Map<String, Int>();
		for (r in results) counts[r.status] = (counts[r.status] ?? 0) + 1;
		var keys = [for (k in counts.keys()) k];
		keys.sort(compare);
		var line = 'Server conformance: ${results.length} requests: ' + [for (k in keys) '$k ${counts[k]}'].join(", ");
		Sys.println(line);
		File.saveContent('$gen/summary.tsv', [for (r in results) '${r.status}\t${r.name}\t${r.detail}\n'].join(""));
		summary(o.get("--summary"), '### server\n\n$line\n\n' + [for (r in results) if (r.status == "FAIL") '- ${r.name}: ${r.detail}\n'].slice(0, 30).join("") + "\n");
		Sys.exit(counts.exists("FAIL") ? 1 : 0);
	}
}

typedef ServerProc = {name:String, port:Int, proc:sys.io.Process, log:String}
typedef ServerOut = {code:String, out:String, err:String}
typedef ServerRes = {name:String, status:String, detail:String, seconds:Float}
