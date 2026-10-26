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
// in its file system. Each request gets a fresh instance, so the program's
// static state starts clean; the compiled module (from the page) and the std
// are reused between instances.

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
					final inst:Dynamic = Syntax.code("new WebAssembly.Instance({0}, {1})", ready[0], host.imports());
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
				final lines = [];
				final add = (line:String) -> lines.push(line);
				var args = ["-cp", ".", "--main", m.main, "--no-output", "-D", "disable-parallelism", "-D", "message.reporting=classic"];
				if (m.type == "display") args = args.concat(["--display", haxe.Json.stringify(m.request)]);
				final t0 = scope.performance.now();
				return runOnce(m.file, m.code, add, add, args).then((status) -> {
					post({type: m.type, id: m.id, status: status, output: lines.join("\n"), ms: scope.performance.now() - t0});
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
