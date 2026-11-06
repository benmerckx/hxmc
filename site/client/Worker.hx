import Protocol;
import WasiHost;
import js.Syntax;
import js.html.DedicatedWorkerGlobalScope;
import js.html.TextDecoder;
import js.lib.Promise;
import js.lib.Uint8Array;
import js.lib.WebAssembly;

// Runs the compiler: hih.wasm (or hih-legacy.wasm: Playground.MODULE), the
// port built by hxmc as a wasm32-wasi module (`make wasm`), with WasiHost as
// its system and the std of std.bundle (`make site`, site/tools/mkbundle.py)
// in its file system. Run and Compile to HXB get a fresh instance each, so
// the program's static state starts clean; display requests and type checks
// go to one instance kept between them (site/compiler/PlaygroundCompiler.hx:
// a compiler.CompilerInstance over a cache that keeps the typed std and the
// modules). The compiled module (from the page) and the std are shared by all.

class Worker {
	static final scope:DedicatedWorkerGlobalScope = Syntax.code("self");
	static var wasmModule:Promise<js.lib.webassembly.Module>;
	static var moduleReady:js.lib.webassembly.Module->Void;
	static var std:Promise<VNode>;

	static function main() {
		wasmModule = new Promise((resolve, _) -> moduleReady = resolve);
		std = scope.fetch(Version.url("std.bundle")).then((r) -> {
			if (!r.ok) throw "std.bundle: " + r.status;
			r.arrayBuffer();
		}).then((b) -> unbundle(new Uint8Array(b)));
		scope.onmessage = (e) -> onRequest(e.data);
	}

	/** /lib/haxe/std from the bundle: a little-endian u32 n, n bytes of JSON
		[[path, size], ...], then the files' bytes in that order */
	static function unbundle(b:Uint8Array):VNode {
		final n = new js.lib.DataView(b.buffer).getUint32(0, true);
		final index:Array<Array<Dynamic>> = haxe.Json.parse(new TextDecoder().decode(b.subarray(4, 4 + n)));
		final lib = new VNode(true);
		final host = new WasiHost(lib, [], [], (_, _) -> {});
		var at = 4 + n;
		for (e in index) {
			final size:Int = e[1];
			host.writeFile("haxe/std/" + e[0], b.subarray(at, at + size));
			at += size;
		}
		return lib;
	}

	static function post(reply:Reply, ?transfer:Array<Dynamic>) {
		scope.postMessage(reply, transfer != null ? transfer : []);
	}

	/** stdout or stderr, as lines: the bytes decoded at each newline, and the
		rest at the end (the compiler ends a --display reply without one) */
	static function lineWriter(emit:String->Void) {
		final decoder = new TextDecoder();
		var bytes:Array<Int> = [];
		function flush() {
			if (bytes.length > 0) emit(decoder.decode(new Uint8Array(bytes)));
			bytes = [];
		}
		return {
			write: (b:Uint8Array) -> for (k in 0...b.length) if (b[k] == 10) flush() else bytes.push(b[k]),
			flush: flush,
		};
	}

	/** a compiler instance with `code` as /work/`file`; `run` calls its main */
	static function instance(file:String, code:String, print:String->Void, printErr:String->Void):Promise<{run:Array<String>->Int}> {
		final out = lineWriter(print), err = lineWriter(printErr);
		return Promise.all([wasmModule, std]).then((ready:Array<Dynamic>) -> {
			final root = new VNode(true);
			root.dir.set("lib", ready[1]);
			return {
				run: (args:Array<String>) -> {
					final host = new WasiHost(root, ["haxe"].concat(args), ["HAXE_STD_PATH" => "/lib/haxe/std/", "PWD" => "/work"],
						(fd, b) -> (fd == 1 ? out : err).write(b));
					host.writeFile("/work/" + file, new js.html.TextEncoder().encode(code));
					final imports:Dynamic = host.imports();
					imports.playground = {serve: (_:Int) -> {}}; // (started as haxe: no requests)
					final inst:Dynamic = Syntax.code("new WebAssembly.Instance({0}, {1})", ready[0], imports);
					host.memory = inst.exports.memory;
					var status = 0, error:Dynamic = null;
					try inst.exports._start() catch (e:Dynamic) error = e;
					out.flush();
					err.flush();
					if (error != null) {
						if (!(error is ExitStatus)) Syntax.code("throw {0}", error); // (as it is: a RangeError, ...)
						status = (error : ExitStatus).status;
					}
					lastHost = host;
					return status;
				}
			};
		});
	}

	static var lastHost:Null<WasiHost>;

	// ---- the kept compiler: display requests and type checks

	/** one instance kept between requests: the module started with PLAYGROUND_SERVER
		(site/compiler/PlaygroundCompiler.hx), whose `request` the worker calls with each
		request in /request and the code in /work */
	static var server:Null<Promise<{host:WasiHost, request:Void->Int, code:String}>>;

	static function startServer():Promise<{host:WasiHost, request:Void->Int, code:String}> {
		return Promise.all([wasmModule, std]).then((ready:Array<Dynamic>) -> {
			final root = new VNode(true);
			root.dir.set("lib", ready[1]);
			final host = new WasiHost(root, ["haxe"], ["HAXE_STD_PATH" => "/lib/haxe/std/", "PWD" => "/work", "PLAYGROUND_SERVER" => "1"], (_, _) -> {});
			final imports:Dynamic = host.imports();
			var index:Null<Int> = null;
			imports.playground = {serve: (i:Int) -> index = i};
			final inst:Dynamic = Syntax.code("new WebAssembly.Instance({0}, {1})", ready[0], imports);
			host.memory = inst.exports.memory;
			try inst.exports._start() catch (e:ExitStatus) if (e.status != 0) throw 'the compiler exited with ${e.status}';
			if (index == null) throw "the compiler did not start";
			final request:Void->Int = inst.exports.__indirect_function_table.get(index);
			return {host: host, request: request, code: ""};
		});
	}

	/** the kept compiler, started if there is none (a start that failed is not kept: the
		next request starts it again) */
	static function kept():Promise<{host:WasiHost, request:Void->Int, code:String}> {
		if (server == null) {
			final s = startServer();
			server = s;
			s.catchError((_) -> if (server == s) server = null);
		}
		return server;
	}

	/** a JSON-RPC request to the kept compiler, on the program `args` builds, with /work/`file`
		holding `code`; the output as lines. An engine fault (engineFault) before the compiler
		printed anything: once more, on a fresh instance (as runOnce) */
	static function serve(file:String, code:String, args:Array<String>, request:Dynamic):Promise<{status:Int, lines:Array<String>}> {
		var printed = false;
		function attempt(retry:Bool):Promise<{status:Int, lines:Array<String>}>
			return serveOn(file, code, args, request, () -> printed = true).catchError((e) -> {
				if (retry && !printed && engineFault(e)) {
					js.Browser.console.warn("The engine faulted, running again:", e != null && e.stack != null ? e.stack : e);
					return attempt(false);
				}
				return Promise.reject(e);
			});
		return attempt(true);
	}

	static function serveOn(file:String, code:String, args:Array<String>, request:Dynamic, onPrint:Void->Void):Promise<{status:Int, lines:Array<String>}> {
		return kept().then((s) -> {
			function call(request:Dynamic):Int {
				s.host.writeFile("/request", new js.html.TextEncoder().encode(haxe.Json.stringify({args: args, request: request})));
				var status = 0;
				try status = s.request() catch (e:Dynamic) {
					// a trap or an exit leaves the instance unusable: the next request starts another
					server = null;
					Syntax.code("throw {0}", e);
				}
				return status;
			}
			// an edit: the file is written, and what the cache keeps of it dropped (server/invalidate,
			// as an editor has it on a change). Only this file in /work: the main class, and so the
			// file, changes with the code
			if (code != s.code || s.host.readFile("/work/" + file) == null) {
				if (s.host.readFile("/work/" + file) == null) s.host.root.dir.set("work", new VNode(true));
				s.host.writeFile("/work/" + file, new js.html.TextEncoder().encode(code));
				s.code = code;
				s.host.out = (_, _) -> {};
				call({jsonrpc: "2.0", id: 0, method: "server/invalidate", params: {file: "/work/" + file}});
			}
			final lines = [];
			function add(line:String) {
				onPrint();
				lines.push(line);
			}
			final out = lineWriter(add), err = lineWriter(add);
			s.host.out = (fd, b) -> (fd == 1 ? out : err).write(b);
			final status = call(request);
			out.flush();
			err.flush();
			return {status: status, lines: lines};
		});
	}

	/** The WebKit of Safari 26.0 (JavaScriptCore) at times runs this module
		wrong: a fault of its own where the program cannot fault, "access to a
		null reference" (its report of an access below any wasm memory, which no
		wasm32 load makes: once in a load from a constant address in a function
		of three instructions) or "Out of bounds memory access"; about once in
		700 compiles, each time elsewhere, with either exception handling, and
		never in Chromium, Firefox, node (also with a collection every 4 KB) or
		the WebKit of Playwright 1.63 (26.6). Such a trap, before the compiler
		printed anything, runs the request once more in a fresh instance (the
		compiler is deterministic: a trap of ours traps again and is reported). */
	static function engineFault(e:Dynamic):Bool {
		return Std.isOfType(e, js.lib.webassembly.RuntimeError)
			&& ~/^(access to a null reference|Out of bounds memory access)/.match(Ui.error(e));
	}

	/** `run` on an instance of `file` with `code`, once more after an engine fault (engineFault) */
	static function runOnce(file:String, code:String, print:String->Void, printErr:String->Void, args:Array<String>):Promise<Int> {
		var printed = false;
		function attempt(retry:Bool):Promise<Int> {
			return instance(file, code, (l) -> {
				printed = true;
				print(l);
			}, (l) -> {
				printed = true;
				printErr(l);
			}).then((c) -> {
				try return Promise.resolve(c.run(args)) catch (e:Dynamic) {
					if (retry && !printed && engineFault(e)) {
						js.Browser.console.warn("The engine faulted, running again:", e != null && e.stack != null ? e.stack : e);
						return attempt(false);
					}
					return Promise.reject(e);
				}
			});
		}
		return attempt(true);
	}

	static function onRequest(m:Request) {
		if (m.type == "module") {
			// the module compiled once by the page
			moduleReady(m.module);
			return;
		}
		final failed = (e:Dynamic) -> {
			// (the stack on the console: a trap's WebAssembly frames, for a bug report)
			js.Browser.console.error("The compiler instance failed:", e != null && e.stack != null ? e.stack : e);
			post({type: "failed", id: m.id, message: "The compiler instance failed: " + Ui.error(e)});
		}
		try handle(m).catchError(failed) catch (e:Dynamic) failed(e);
	}

	static function handle(m:Request):Promise<Void> {
		switch m.type {
			case "warmup":
				// (one run: the engine compiles the module's code meanwhile; once
				// more after an engine fault, as a request's)
				return runOnce("Main.hx", "", (_) -> {}, (_) -> {}, ["--version"]).then((_) -> {
					post({type: "ready"});
				});
			case "display" | "check":
				final args = ["-cp", ".", "--main", m.main, "--no-output", "-D", "disable-parallelism"];
				// (a check: the file's diagnostics, a request too)
				final request = m.type == "display" ? m.request : {jsonrpc: "2.0", id: 1, method: "display/diagnostics", params: {file: "/work/" + m.file}};
				final t0 = scope.performance.now();
				return serve(m.file, m.code, args, request).then((r) -> {
					post({type: m.type, id: m.id, status: r.status, output: r.lines.join("\n"), ms: scope.performance.now() - t0});
				});
			case _:
				final args = ["-cp", ".", "--main", m.main, "-D", "disable-parallelism"]
					.concat(m.mode == "run" ? ["--interp"] : ["--hxb", "/out.zip", "--no-output"]);
				final t0 = scope.performance.now();
				return runOnce(m.file, m.code, (text) -> post({type: "out", text: text}), (text) -> post({type: "err", text: text}), args).then((status) -> {
					final ms = scope.performance.now() - t0;
					final bytes = m.mode == "hxb" && status == 0 ? lastHost.readFile("/out.zip") : null;
					final zip = bytes == null ? null : bytes.slice().buffer;
					post({type: "done", status: status, ms: ms, zip: zip}, zip != null ? [zip] : []);
				});
		}
	}
}
