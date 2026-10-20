import Harness.*;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.net.Socket;

using StringTools;

// Eval debugger conformance (`-D eval-debugger=host:port`):
//   <haxe> -cp haxe/test --run EvalDebugger [--keep] [--summary <file>] [--shard <i>/<n>] [scenario ...]
// --shard i/n runs every n-th scenario from the i-th (1-based): CI's n jobs
// together run them all.
// The Eval debugger is a JSON-RPC client: the compiler connects to the
// debugger (here this script) at host:port, waits for a `continue`, and
// answers requests while the program runs or stands at a breakpoint. Frames:
// the debugger sends a 2-byte little-endian length then the JSON text, the
// compiler a 4-byte little-endian length then the JSON text. The reference and
// the port go through the same scripted sessions over haxe/test/eval-debugger
// (breakpoints, conditions, stepping, stack traces, scopes, variables,
// evaluation, assignment, exception stops, function breakpoints, a macro);
// every message each sends (after each request its response, then the
// events in arrival order), its stdout, stderr and exit code are compared.
// Normalized: the host's thread number in "Thread N killed", and the
// response to a request after which the program ran to its end (a race).
// `getCompletion` is not exercised (upstream's handler kills the debugger
// thread).
class EvalDebugger {
	static final TIMEOUT = 15.0;
	static final STEP_WAIT = 1.0;
	static final T0 = '{"threadId":0}';
	static var cases:String;

	static function main() {
		var a = parseArgs(Sys.args(), ["--summary", "--shard"]);
		var ref = FileSystem.fullPath(Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe");
		var port = FileSystem.fullPath(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		cases = root + "/haxe/test/eval-debugger";
		var out = "bin/test/eval-debugger";
		mkdirs(out);
		var shard = a.has("--shard") ? a.get("--shard").split("/").map(Std.parseInt) : [1, 1];
		if (shard.length != 2 || shard[0] == null || shard[1] == null || shard[0] < 1 || shard[0] > shard[1])
			throw "--shard: <i>/<n> with 1 <= i <= n";
		var names = [
			for (i => s in SCENARIOS)
				if ((a.rest.length == 0 || a.rest.contains(s.name)) && i % shard[1] == shard[0] - 1) s
		];
		var failed = 0, lines = [];
		for (s in names) {
			var r = normalize(run(ref, s)), p = normalize(run(port, s));
			if (a.has("--keep") || r != p) {
				File.saveContent('$out/${s.name}.reference.txt', r);
				File.saveContent('$out/${s.name}.port.txt', p);
			}
			var line = r == p ? 'ok   ${s.name}' : 'FAIL ${s.name} (see $out/${s.name}.*.txt)';
			if (r != p) failed++;
			Sys.println(line);
			lines.push(line);
		}
		var total = '${names.length - failed}/${names.length} scenarios identical';
		Sys.println(total);
		var title = shard[1] > 1 ? 'Eval debugger (shard ${shard[0]}/${shard[1]})' : "Eval debugger";
		summary(a.get("--summary"), '### $title\n\n$total\n\n```\n${lines.join("\n")}\n```\n\n');
		Sys.exit(failed > 0 ? 1 : 0);
	}

	static final SCENARIOS:Array<{name:String, main:String, f:Session->Void}> = [
		{name: "breakpoints", main: "Main", f: breakpoints},
		{name: "set-variable", main: "Main", f: setVariable},
		{name: "exceptions", main: "Main", f: exceptions},
		{name: "function-breakpoints", main: "Main", f: functionBreakpoints},
		{name: "errors", main: "Main", f: errors},
		{name: "macro", main: "MacroMain", f: macroScenario},
	];

	static function run(compiler:String, s:{name:String, main:String, f:Session->Void}):Transcript {
		var session = new Session(compiler, ["-main", s.main, "--interp"], cases);
		try s.f(session) catch (e:Dynamic) session.log.push({request: "harness-error", response: Std.string(e), events: [], eof: false});
		return session.finish();
	}

	static function normalize(t:Transcript):String {
		var b = new StringBuf();
		for (e in t.log) {
			var response = e.response;
			if (e.eof) response = "<maybe>";
			b.add('> ${e.request}\n< $response\n');
			for (ev in e.events) b.add('! $ev\n');
		}
		for (m in t.trailing) b.add('! $m\n');
		b.add('--- stdout\n${t.stdout}\n--- stderr\n${~/Thread [0-9]+ killed/g.replace(t.stderr, "Thread N killed")}\n--- exit ${t.exit}\n');
		return b.toString().replace(cases, "<cases>");
	}

	static function canonical(j:Dynamic):String {
		if (j == null) return "null";
		if (Std.isOfType(j, String)) return haxe.Json.stringify(j);
		if (Std.isOfType(j, Array)) return "[" + [for (x in (j : Array<Dynamic>)) canonical(x)].join(",") + "]";
		if (Reflect.isObject(j)) {
			var keys = Reflect.fields(j);
			keys.sort(compare);
			return "{" + [for (k in keys) haxe.Json.stringify(k) + ":" + canonical(Reflect.field(j, k))].join(",") + "}";
		}
		return haxe.Json.stringify(j);
	}

	// scopes of a frame, their variables and (to depth) the variables' children
	static function inspectFrame(s:Session, frame = 1, depth = 1) {
		var scopes:Array<Dynamic> = s.result("getScopes", '{"frameId":$frame}') ?? [];
		for (sc in scopes) {
			var vars:Array<Dynamic> = s.result("getVariables", '{"id":${sc.id}}') ?? [];
			if (depth > 0) for (v in vars) if (v.id != null && v.id != 0) s.result("getVariables", '{"id":${v.id}}');
		}
	}

	static function ev(s:Session, expr:String) s.result("evaluate", '{"expr":${haxe.Json.stringify(expr)},"frameId":1}');

	static function breakpoints(s:Session) {
		s.result("setBreakpoints", '{"file":"Main.hx","breakpoints":[{"line":26},{"line":38},{"line":46,"condition":"i == 1"}]}');
		s.result("setExceptionOptions", '["uncaught"]');
		s.request("continue", T0, true);
		s.result("getThreads", "{}");
		s.result("stackTrace", T0);
		inspectFrame(s);
		for (e in ["a + 1", "b.length", "b.charAt(0) + c", "b.charCodeAt(2)", "var q = 5", "q * 2", "nope(", "counter", "Main.counter + 1", "[a, 2, 3].length", "{x: a}"]) ev(s, e);
		s.step("next");
		s.result("stackTrace", T0);
		s.step("next");
		s.result("stackTrace", T0);
		inspectFrame(s);
		s.step("stepOut");
		s.result("stackTrace", T0);
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		inspectFrame(s, 1, 1);
		for (e in ["p.sum()", "p.x * 10", "col", "o.name", "m", "new Point(1, 2)", "arr[1]", "r = 100", "r"]) ev(s, e);
		s.step("stepIn");
		s.result("stackTrace", T0);
		s.step("stepIn");
		s.result("stackTrace", T0);
		inspectFrame(s);
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		inspectFrame(s, 1, 0);
		s.result("removeBreakpoint", '{"id":3}');
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.request("continue", T0, true);
	}

	static function setVariable(s:Session) {
		s.result("setBreakpoints", '{"file":"Main.hx","breakpoints":[{"line":39}]}');
		s.result("setExceptionOptions", '["none"]');
		s.request("continue", T0, true);
		var scopes:Array<Dynamic> = s.result("getScopes", '{"frameId":1}') ?? [];
		for (sc in scopes) {
			var vars:Array<Dynamic> = s.result("getVariables", '{"id":${sc.id}}') ?? [];
			var names = new Map<String, Dynamic>();
			for (v in vars) names[v.name] = v;
			function set(id:Dynamic, name:String, value:String) s.result("setVariable", '{"id":$id,"name":${haxe.Json.stringify(name)},"value":${haxe.Json.stringify(value)}}');
			if (names.exists("r")) set(sc.id, "r", "7");
			if (names.exists("arr") && names["arr"].id != null && names["arr"].id != 0) {
				set(names["arr"].id, "[1]", "20");
				s.result("getVariables", '{"id":${names["arr"].id}}');
			}
			if (names.exists("o") && names["o"].id != null && names["o"].id != 0) {
				set(names["o"].id, "value", '"changed"');
				s.result("getVariables", '{"id":${names["o"].id}}');
			}
			if (names.exists("arr")) set(sc.id, "t", "1.5");
			s.result("getVariables", '{"id":${sc.id}}');
		}
		s.result("setVariable", '{"id":9999,"name":"x","value":"1"}');
		s.result("getVariables", '{"id":9999}');
		s.request("continue", T0, true);
	}

	static function exceptions(s:Session) {
		s.result("setExceptionOptions", '["all"]');
		s.result("setBreakpoints", '{"file":"Main.hx","breakpoints":[]}');
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		inspectFrame(s, 1, 0);
		s.result("setExceptionOptions", '["uncaught"]');
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.request("continue", T0, true);
	}

	static function functionBreakpoints(s:Session) {
		s.result("setFunctionBreakpoints", '[{"name":"Main.helper"},{"name":"Point.sum"}]');
		s.result("setExceptionOptions", '["none"]');
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.step("next");
		s.result("stackTrace", T0);
		inspectFrame(s, 1, 0);
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.request("pause", T0);
		s.request("continue", T0, true);
		s.request("continue", T0, true);
	}

	static function errors(s:Session) {
		s.result("setBreakpoint", '{"file":"Main.hx","breakpoint":{"line":27,"column":3}}');
		s.result("setBreakpoint", '{"file":"Main.hx","breakpoint":{"line":33}}');
		s.result("noSuchMethod", "{}");
		s.result("getScopes", '{"frameId":77}');
		s.result("getVariables", '{"id":0}');
		s.result("stackTrace", '{"threadId":5}');
		s.result("setExceptionOptions", '["none"]');
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.request("continue", T0, true);
	}

	// a breakpoint in a macro function: the macro context's interpreter stops
	// while the compiler types MacroMain, then the program runs in the second
	// (--interp) context, which shares the breakpoints
	static function macroScenario(s:Session) {
		s.result("setBreakpoints", '{"file":"MacroMain.hx","breakpoints":[{"line":13},{"line":5}]}');
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		inspectFrame(s);
		ev(s, "n + 1");
		ev(s, "e.pos");
		s.step("next");
		s.result("stackTrace", T0);
		inspectFrame(s, 1, 0);
		s.request("continue", T0, true);
		s.result("stackTrace", T0);
		s.request("continue", T0, true);
	}
}

typedef Entry = {request:String, response:Null<String>, events:Array<String>, eof:Bool}
typedef Transcript = {log:Array<Entry>, trailing:Array<String>, stdout:String, stderr:String, exit:Int}

class Session {
	public var log:Array<Entry> = [];

	var srv:Socket;
	var conn:Socket;
	var proc:sys.io.Process;
	var buf = Bytes.alloc(0);
	var closed = false;
	var rid = 0;
	var outFile:String;
	var errFile:String;

	public function new(compiler:String, args:Array<String>, cwd:String) {
		srv = new Socket();
		srv.bind(new sys.net.Host("127.0.0.1"), 0);
		srv.listen(1);
		var port = srv.host().port;
		var t = tempName();
		outFile = t + ".out";
		errFile = t + ".err";
		proc = new sys.io.Process("/bin/sh", ["-c", 'exec "$$@" >' + quote(outFile) + ' 2>' + quote(errFile) + ' </dev/null', "sh", compiler, "--cwd", cwd]
			.concat(args).concat(["-D", 'eval-debugger=127.0.0.1:$port']));
		srv.setTimeout(60);
		conn = srv.accept();
	}

	// one message, null at the end of the connection, "timeout"
	function recv(timeout:Float):Null<String> {
		var deadline = now() + timeout;
		while (true) {
			if (buf.length >= 4) {
				var n = buf.getInt32(0);
				if (buf.length >= 4 + n) {
					var m = buf.getString(4, n);
					buf = buf.sub(4 + n, buf.length - 4 - n);
					return m;
				}
			}
			if (closed) return null;
			var left = deadline - now();
			if (left <= 0) return "timeout";
			var ready = Socket.select([conn], [], [], left);
			if (ready.read.length == 0) return "timeout";
			var chunk = Bytes.alloc(65536);
			var k = try conn.input.readBytes(chunk, 0, chunk.length) catch (_:haxe.io.Eof) 0;
			if (k <= 0) {
				closed = true;
				continue;
			}
			var nb = Bytes.alloc(buf.length + k);
			nb.blit(0, buf, 0, buf.length);
			nb.blit(buf.length, chunk, 0, k);
			buf = nb;
		}
	}

	// sends a request; reads until its response (and, with waitStop, until a stop
	// event or the end of the connection), then whatever arrives within drain seconds
	public function request(method:String, ?params:String, waitStop = false, drain = 0.3):Null<String> {
		rid++;
		var o = '{"jsonrpc":"2.0","id":$rid,"method":${haxe.Json.stringify(method)}' + (params != null ? ',"params":$params' : "") + "}";
		var s = Bytes.ofString(o);
		var len = Bytes.alloc(2);
		len.setUInt16(0, s.length);
		conn.output.write(len);
		conn.output.write(s);
		conn.output.flush();
		var response:Null<String> = null, events = [], stopped = false, eof = false;
		var deadline = now() + TIMEOUT;
		while (response == null || (waitStop && !stopped)) {
			var m = recv(Math.max(0, deadline - now()));
			if (m == "timeout") {
				events.push('{"harness":"timeout"}');
				break;
			}
			if (m == null) {
				events.push('{"harness":"eof"}');
				eof = true;
				stopped = true;
				if (response == null) break;
				continue;
			}
			var isEvent = try Reflect.hasField(haxe.Json.parse(m), "method") catch (_:Dynamic) false;
			if (isEvent) {
				events.push(m);
				if (m.indexOf('"breakpointStop"') >= 0 || m.indexOf('"exceptionStop"') >= 0) stopped = true;
			} else
				response = m;
		}
		while (!closed) {
			var m = recv(drain);
			if (m == "timeout" || m == null) break;
			events.push(m);
		}
		log.push({request: o, response: response, events: events, eof: eof});
		return response;
	}

	static inline var TIMEOUT = 15.0;

	// stepping sends no event: the program stands again once it reaches the next
	// debug point (assumed within a second)
	public function step(method:String) return request(method, '{"threadId":0}', false, 1.0);

	public function result(method:String, ?params:String):Dynamic {
		var r = request(method, params);
		return try haxe.Json.parse(r).result catch (_:Dynamic) null;
	}

	public function finish():Transcript {
		var deadline = now() + 60;
		while (Server.alive(proc) && now() < deadline) Sys.sleep(0.05);
		var killed = false;
		if (Server.alive(proc)) {
			proc.kill();
			killed = true;
		}
		var exit = proc.exitCode();
		proc.close();
		var rest = [];
		while (!closed) {
			var m = recv(0.5);
			if (m == "timeout" || m == null) break;
			rest.push(m);
		}
		conn.close();
		srv.close();
		var t:Transcript = {log: log, trailing: rest, stdout: readText(outFile), stderr: readText(errFile) + (killed ? "\n<harness: killed after timeout>" : ""), exit: exit};
		FileSystem.deleteFile(outFile);
		FileSystem.deleteFile(errFile);
		return t;
	}
}
