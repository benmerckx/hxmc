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
// in its file system. One instance is kept for every request
// (site/compiler/PlaygroundCompiler.hx: a compiler.CompilerInstance over a cache
// that keeps the typed std and the modules): display requests and checks, Run
// (a build with --interp: each runs its program in an interpreter of its own) and
// Compile to HXB (a clean build). A trap or an exit drops it; the next request
// starts another. The compiled module comes from the page.

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


	// ---- the kept compiler

	/** the instance kept between requests, whose `request` the worker calls with each
		request in /request and the code in /work */
	static var server:Null<Promise<Kept>>;

	static function startServer():Promise<Kept> {
		return Promise.all([wasmModule, std]).then((ready:Array<Dynamic>) -> {
			final root = new VNode(true);
			root.dir.set("lib", ready[1]);
			final host = new WasiHost(root, ["haxe"], ["HAXE_STD_PATH" => "/lib/haxe/std/", "PWD" => "/work"], (_, _) -> {});
			final imports:Dynamic = host.imports();
			var index:Null<Int> = null;
			imports.playground = {serve: (i:Int) -> index = i};
			final inst:Dynamic = Syntax.code("new WebAssembly.Instance({0}, {1})", ready[0], imports);
			host.memory = inst.exports.memory;
			try inst.exports._start() catch (e:ExitStatus) if (e.status != 0) throw 'the compiler exited with ${e.status}';
			if (index == null) throw "the compiler did not start";
			final request:Void->Int = inst.exports.__indirect_function_table.get(index);
			return {host: host, request: request, code: null};
		});
	}

	/** the kept compiler, started if there is none (a start that failed is not kept: the
		next request starts it again) */
	static function kept():Promise<Kept> {
		if (server == null) {
			final s = startServer();
			server = s;
			s.catchError((_) -> if (server == s) server = null);
		}
		return server;
	}

	/** `r` ({args, ?request, ?clean}) to the kept compiler `s`; its result. A trap or an exit
		drops the instance: the next request starts another */
	static function invoke(s:Kept, r:Dynamic):Int {
		s.host.writeFile("/request", new js.html.TextEncoder().encode(haxe.Json.stringify(r)));
		var status = 0;
		try status = s.request() catch (e:Dynamic) {
			server = null;
			Syntax.code("throw {0}", e);
		}
		return status;
	}

	/** A request to the kept compiler on /work/`file` holding `code` (null: no file): written,
		and what the cache keeps of it dropped (server/invalidate, as an editor has it on a
		change; a write within the same second does not show it). Only this file in /work:
		the main class, and so the file, changes with the code. Its output to `onOut` and
		`onErr` as lines. An engine fault (engineFault) before anything was printed: once
		more, on a fresh instance */
	static function call(file:Null<String>, code:String, r:{args:Array<String>, ?request:Dynamic, ?clean:Bool}, onOut:String->Void,
			onErr:String->Void):Promise<Int> {
		var printed = false;
		function attempt(retry:Bool):Promise<Int>
			return kept().then((s) -> {
				if (file != null && (code != s.code || s.host.readFile("/work/" + file) == null)) {
					if (s.host.readFile("/work/" + file) == null) s.host.root.dir.set("work", new VNode(true));
					s.host.writeFile("/work/" + file, new js.html.TextEncoder().encode(code));
					s.code = code;
					s.host.out = (_, _) -> {};
					invoke(s, {args: r.args, request: {jsonrpc: "2.0", id: 0, method: "server/invalidate", params: {file: "/work/" + file}}});
				}
				final out = lineWriter((l) -> {
					printed = true;
					onOut(l);
				}), err = lineWriter((l) -> {
					printed = true;
					onErr(l);
				});
				s.host.out = (fd, b) -> (fd == 1 ? out : err).write(b);
				final status = invoke(s, r);
				out.flush();
				err.flush();
				return status;
			}).catchError((e) -> {
				if (retry && !printed && engineFault(e)) {
					js.Browser.console.warn("The engine faulted, running again:", e != null && e.stack != null ? e.stack : e);
					return attempt(false);
				}
				return Promise.reject(e);
			});
		return attempt(true);
	}

	/** the compiler's arguments for `main`: --interp, so checks and runs type for the same
		platform (Eval) and share what the cache keeps */
	static function argsFor(main:String):Array<String>
		return ["-cp", ".", "--main", main, "-D", "disable-parallelism", "--interp"];

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
				// (the kept compiler started: the engine compiles the module's code meanwhile)
				return call(null, "", {args: ["--version"]}, (_) -> {}, (_) -> {}).then((_) -> post({type: "ready"}));
			case "display" | "check":
				// (a check: the file's diagnostics, a request too)
				final request = m.type == "display" ? m.request : {jsonrpc: "2.0", id: 1, method: "display/diagnostics", params: {file: "/work/" + m.file}};
				final lines = [];
				final t0 = scope.performance.now();
				return call(m.file, m.code, {args: argsFor(m.main), request: request}, lines.push, lines.push).then((status) -> {
					post({type: m.type, id: m.id, status: status, output: lines.join("\n"), ms: scope.performance.now() - t0});
				});
			case _:
				final hxb = m.mode != "run";
				final args = hxb ? ["-cp", ".", "--main", m.main, "-D", "disable-parallelism", "--hxb", "/out.zip", "--no-output"] : argsFor(m.main);
				final t0 = scope.performance.now();
				return kept().then((s) -> {
					s.host.root.dir.remove("out.zip");
					return call(m.file, m.code, {args: args, clean: hxb}, (text) -> post({type: "out", text: text}), (text) -> post({type: "err", text: text}));
				}).then((status) -> {
					final ms = scope.performance.now() - t0;
					final bytes = hxb && status == 0 ? server.then((s) -> s.host.readFile("/out.zip")) : Promise.resolve(null);
					return bytes.then((bytes) -> {
						final zip = bytes == null ? null : (bytes : Uint8Array).slice().buffer;
						post({type: "done", status: status, ms: ms, zip: zip}, zip != null ? [zip] : []);
					});
				});
		}
	}
}

/** the kept compiler: its system, its request function, the code /work holds (null: none yet) */
typedef Kept = {host:WasiHost, request:Void->Int, code:Null<String>};
