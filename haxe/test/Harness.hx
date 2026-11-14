import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

using StringTools;

// What the test scripts share: processes (working directory, environment,
// output to a log, a time limit), a pool of threads, ZIP archives, files.
// The scripts run on Eval with our compiler, from the repository root:
//   bin/hxmc/hxmc -cp haxe/test --run <Script> <args>
// (or any build of the port, e.g. a release binary on another machine).
class Harness {
	public static var windows(get, never):Bool;

	static function get_windows() return Sys.systemName() == "Windows";

	// the repository root (the working directory the scripts run in)
	public static var root(get, never):String;

	static function get_root() return Path.removeTrailingSlashes(FileSystem.fullPath("."));

	public static function cpus():Int {
		var env = Sys.getEnv("JOBS");
		if (env != null && Std.parseInt(env) != null) return Std.parseInt(env);
		if (windows) {
			var n = Std.parseInt(Sys.getEnv("NUMBER_OF_PROCESSORS") ?? "");
			return n == null ? 4 : n;
		}
		var r = exec(["sh", "-c", "nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu"]);
		var n = Std.parseInt(r.out.trim());
		return n == null || n < 1 ? 4 : n;
	}

	public static function now():Float return haxe.Timer.stamp();

	/**
		Runs `cmd`. Options: `cwd` (the working directory), `env` (variables set
		for this process; a null value unsets), `log` (stdout and stderr go to
		this file instead of being returned), `timeout` (seconds; then the process
		and the ones it started are killed, as hxmc's tool runs itself again,
		hxmc.Main: `timedOut` and code -1), `merge` (stderr into stdout), `stdin`
		(a file), `inherit` (this process's stdin, stdout and stderr: nothing
		captured). Windows, and with `inherit`: through libuv (spawn;
		HARNESS_LUV=1 elsewhere too).
	**/
	public static function exec(cmd:Array<String>, ?o:ExecOptions):ExecResult {
		if (o == null) o = {};
		if (windows || o.inherit == true || Sys.getEnv("HARNESS_LUV") == "1") return spawn(cmd, o);
		var t0 = now();
		var tmp = o.log == null ? tempName() : null;
		var outFile = o.log != null ? o.log : tmp + ".out";
		var errFile = o.log != null || o.merge == true ? null : tmp + ".err";
		var script = new StringBuf();
		script.add('cd "$$1" || exit 126; shift; ');
		if (o.env != null)
			for (k => v in o.env)
				script.add(v == null ? 'unset $k; ' : 'export $k=${quote(v)}; ');
		var redir = ' >${quote(outFile)} 2>' + (errFile == null ? '&1' : quote(errFile)) + (o.stdin != null ? ' <' + quote(o.stdin) : ' </dev/null');
		if (o.timeout != null) {
			var t = Std.int(Math.ceil(o.timeout));
			// (k: a process and its descendants, each stopped first, so it neither
			// starts more nor ends before them)
			script.add('k() { kill -STOP $$1; for c in $$(pgrep -P $$1); do k $$c; done; kill -9 $$1; }; ');
			// (the watchdog is ended as a timed-out process is, by k, which takes its
			// sleep with it: left running, every process run would leave one behind for
			// `t` seconds, which fills the process table; a trap killing the sleep
			// missed it when the signal came before the sleep's pid was known; r, not
			// c: k's loop sets c)
			script.add('"$$@"$redir & p=$$!; (sleep $t; k $$p) >/dev/null 2>&1 & w=$$!; wait $$p; r=$$?; k $$w 2>/dev/null; exit $$r');
		} else
			script.add('exec "$$@"$redir');
		var p = new sys.io.Process("/bin/sh", ["-c", script.toString(), "sh", o.cwd == null ? "." : o.cwd].concat(cmd));
		var code = p.exitCode();
		p.close();
		var dt = now() - t0;
		var r:ExecResult = {code: code, out: "", err: "", seconds: dt, timedOut: o.timeout != null && code == 137 && dt >= o.timeout};
		if (r.timedOut) r.code = -1;
		if (tmp != null) {
			r.out = readText(outFile);
			if (errFile != null) r.err = readText(errFile);
			try FileSystem.deleteFile(outFile) catch (_:Dynamic) {}
			if (errFile != null) try FileSystem.deleteFile(errFile) catch (_:Dynamic) {}
		}
		return r;
	}

	// The process through libuv (eval.luv, on an event loop of this call's),
	// without a shell (Windows has no /bin/sh), which gives a child its own
	// working directory and environment, so the harness's own stay as they are
	// and threads start processes at once. stdout and stderr through pipes (with
	// merge, stderr after stdout), stdin a pipe the file is written to; the
	// timeout ends the process (Windows: its tree, taskkill /T; elsewhere the
	// process alone)
	public static function spawn(cmd:Array<String>, ?o:ExecOptions):ExecResult {
		if (o == null) o = {};
		var t0 = now();
		var r:ExecResult = {code: -1, out: "", err: "", seconds: 0, timedOut: false};
		var loop = eval.luv.Loop.init().resolve();
		// (Windows: names in any case, PATH as Path)
		var env = new Map<String, eval.NativeString>();
		for (k => v in Sys.environment())
			env[k] = v;
		if (o.env != null)
			for (k => v in o.env) {
				for (e in [for (e in env.keys()) e])
					if (e == k || (windows && e.toUpperCase() == k.toUpperCase())) env.remove(e);
				if (v != null) env[k] = v;
			}
		var inherit = o.inherit == true;
		var outPipe = inherit ? null : eval.luv.Pipe.init(loop).resolve(), errPipe = inherit ? null : eval.luv.Pipe.init(loop).resolve();
		var inPipe = o.stdin == null || inherit ? null : eval.luv.Pipe.init(loop).resolve();
		var redirect = inherit ? [for (fd in 0...3) eval.luv.Process.inheritFd(fd, fd)] : [
			eval.luv.Process.toParentPipe(eval.luv.Process.stdout, outPipe, false, true, false),
			eval.luv.Process.toParentPipe(eval.luv.Process.stderr, errPipe, false, true, false)
		];
		if (inherit) Sys.stdout().flush();
		if (inPipe != null) redirect.push(eval.luv.Process.toParentPipe(eval.luv.Process.stdin, inPipe, true, false, false));
		var done = false;
		var timer:Null<eval.luv.Timer> = null;
		var spawned = eval.luv.Process.spawn(loop, cmd[0], [for (a in cmd) (a : eval.NativeString)], {
			environment: env,
			workingDirectory: o.cwd,
			redirect: redirect,
			windowsHide: true,
			// (a signal's end as the shell reports it: 128 + its number)
			onExit: (p, status, signal) -> {
				r.code = signal != 0 ? 128 + signal : status.toInt();
				done = true;
				if (timer != null) {
					timer.stop();
					timer.close(() -> {});
				}
				p.close(() -> {});
			}
		});
		var pipes:Array<eval.luv.Handle> = inherit ? [] : [outPipe, errPipe];
		if (inPipe != null) pipes.push(inPipe);
		switch spawned {
			case Error(e):
				for (h in pipes)
					eval.luv.Handle.close(h, () -> {});
				loop.run(DEFAULT);
				loop.close();
				r.code = 127;
				r.err = cmd[0] + ": " + e.toString();
				r.seconds = now() - t0;
				return r;
			case Ok(p):
				if (o.timeout != null) {
					timer = eval.luv.Timer.init(loop).resolve();
					timer.start(() -> {
						if (done) return;
						r.timedOut = true;
						if (windows) {
							var k = new sys.io.Process("taskkill", ["/T", "/F", "/PID", Std.string(p.pid())]);
							k.exitCode();
							k.close();
						} else
							eval.luv.Process.killPid(p.pid(), SIGKILL);
					}, Std.int(o.timeout * 1000));
				}
		}
		var out = new haxe.io.BytesBuffer(), err = new haxe.io.BytesBuffer();
		function read(pipe:eval.luv.Pipe, to:haxe.io.BytesBuffer)
			eval.luv.Stream.readStart(pipe, res -> switch res {
				case Ok(b): to.add(b.toBytes());
				case Error(_): pipe.close(() -> {});
			});
		if (!inherit) {
			read(outPipe, out);
			read(errPipe, err);
		}
		if (inPipe != null) {
			var data = eval.luv.Buffer.fromBytes(File.getBytes(o.stdin));
			eval.luv.Stream.write(inPipe, [data], (_, _) -> inPipe.close(() -> {}));
		}
		loop.run(DEFAULT);
		loop.close();
		var so = out.getBytes().toString(), se = err.getBytes().toString();
		if (r.timedOut) r.code = -1;
		if (o.merge == true || o.log != null) so += se else r.err = se;
		if (o.log != null) File.saveContent(o.log, so) else r.out = so;
		r.seconds = now() - t0;
		return r;
	}

	static var tempCount = 0;
	static var tempMutex = new Mutex();

	public static function tempName():String {
		tempMutex.acquire();
		var n = tempCount++;
		tempMutex.release();
		var dir = Sys.getEnv("TMPDIR") ?? "/tmp";
		return '$dir/harness-${Std.int(Sys.time() * 1000) % 1000000000}-${Std.random(1000000)}-$n';
	}

	public static function quote(s:String):String return "'" + s.replace("'", "'\\''") + "'";

	public static function readText(path:String):String
		return try File.getContent(path) catch (_:Dynamic) "";

	/** Calls `f` on every item on `jobs` threads; `done` is called in the items' order. **/
	public static function parallel<T, R>(items:Array<T>, jobs:Int, f:T->R, ?done:(T, R) -> Void):Array<R> {
		var results:Array<Null<R>> = [for (_ in items) null];
		var finished = [for (_ in items) false];
		var m = new Mutex();
		var next = 0, reported = 0;
		var all = new Lock();
		var workers = jobs < 1 ? 1 : jobs > items.length ? items.length : jobs;
		if (items.length == 0) return [];
		for (_ in 0...workers)
			Thread.create(() -> {
				while (true) {
					m.acquire();
					var i = next++;
					m.release();
					if (i >= items.length) break;
					var r = try f(items[i]) catch (e:Dynamic) {
						Sys.println("harness: " + Std.string(e) + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
						null;
					}
					m.acquire();
					results[i] = r;
					finished[i] = true;
					while (reported < items.length && finished[reported]) {
						if (done != null) done(items[reported], results[reported]);
						reported++;
					}
					m.release();
				}
				all.release();
			});
		for (_ in 0...workers) all.wait();
		return results;
	}

	/** The words of a shell-like line (quotes and backslashes as Python's shlex.split). **/
	public static function shellSplit(s:String, comments = false):Array<String> {
		var words = [], cur = new StringBuf(), has = false, i = 0;
		while (i < s.length) {
			var c = s.charAt(i);
			if (c == "'") {
				var j = s.indexOf("'", i + 1);
				if (j < 0) throw "unclosed quote: " + s;
				cur.add(s.substring(i + 1, j));
				has = true;
				i = j + 1;
			} else if (c == '"') {
				i++;
				while (i < s.length && s.charAt(i) != '"') {
					if (s.charAt(i) == "\\" && i + 1 < s.length && '"\\$`'.indexOf(s.charAt(i + 1)) >= 0) i++;
					cur.add(s.charAt(i));
					i++;
				}
				if (i >= s.length) throw "unclosed quote: " + s;
				has = true;
				i++;
			} else if (c == "\\" && i + 1 < s.length) {
				cur.add(s.charAt(i + 1));
				has = true;
				i += 2;
			} else if (c == " " || c == "\t" || c == "\n" || c == "\r") {
				if (has) words.push(cur.toString());
				cur = new StringBuf();
				has = false;
				i++;
			} else if (comments && c == "#" && !has) {
				while (i < s.length && s.charAt(i) != "\n") i++;
			} else {
				cur.add(c);
				has = true;
				i++;
			}
		}
		if (has) words.push(cur.toString());
		return words;
	}

	// files

	public static function rmrf(path:String) {
		if (!windows) {
			exec(["rm", "-rf", path]);
			return;
		}
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (n in FileSystem.readDirectory(path)) rmrf(path + "/" + n);
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}

	public static function mkdirs(path:String) FileSystem.createDirectory(path);

	public static function copyTree(src:String, dst:String) {
		if (FileSystem.isDirectory(src)) {
			FileSystem.createDirectory(dst);
			for (n in FileSystem.readDirectory(src)) copyTree(src + "/" + n, dst + "/" + n);
		} else
			File.copy(src, dst);
	}

	/** The files under `dir` (relative paths, sorted). **/
	public static function walk(dir:String, ?ext:String):Array<String> {
		var out = [];
		function go(rel:String) {
			var d = rel == "" ? dir : dir + "/" + rel;
			for (n in FileSystem.readDirectory(d)) {
				var r = rel == "" ? n : rel + "/" + n;
				if (FileSystem.isDirectory(dir + "/" + r)) go(r) else if (ext == null || r.endsWith(ext)) out.push(r);
			}
		}
		go("");
		out.sort(compare);
		return out;
	}

	public static function compare(a:String, b:String):Int return a < b ? -1 : a > b ? 1 : 0;

	public static function mtime(path:String):Float return FileSystem.stat(path).mtime.getTime();

	/** The newest modification time of a file or of the .hx files under a directory. **/
	public static function newest(paths:Array<String>):Float {
		var t = 0.0;
		for (p in paths) {
			if (!FileSystem.exists(p)) continue;
			if (!FileSystem.isDirectory(p)) t = Math.max(t, mtime(p)) else for (f in walk(p, ".hx")) t = Math.max(t, mtime(p + "/" + f));
		}
		return t;
	}

	// ZIP archives (HXB)

	/** The members of a ZIP archive, uncompressed, in the central directory's order. **/
	public static function readZip(path:String):Zip {
		var b = File.getBytes(path);
		var eocd = b.length - 22;
		while (eocd >= 0 && b.getInt32(eocd) != 0x06054b50) eocd--;
		if (eocd < 0) throw path + ": not a ZIP archive";
		var count = b.getUInt16(eocd + 10);
		var p = b.getInt32(eocd + 16);
		var z = new Zip();
		for (_ in 0...count) {
			if (b.getInt32(p) != 0x02014b50) throw path + ": bad central directory";
			var method = b.getUInt16(p + 10);
			var csize = b.getInt32(p + 20), usize = b.getInt32(p + 24);
			var nlen = b.getUInt16(p + 28), xlen = b.getUInt16(p + 30), clen = b.getUInt16(p + 32);
			var local = b.getInt32(p + 42);
			var name = b.getString(p + 46, nlen);
			p += 46 + nlen + xlen + clen;
			var start = local + 30 + b.getUInt16(local + 26) + b.getUInt16(local + 28);
			var raw = b.sub(start, csize);
			z.names.push(name);
			z.data[name] = method == 0 ? raw : inflate(raw, usize);
		}
		return z;
	}

	/** Raw deflate data (no zlib header) of a known size. **/
	public static function inflate(raw:Bytes, size:Int):Bytes {
		#if eval
		var u = new haxe.zip.Uncompress(-15);
		var out = Bytes.alloc(size);
		var src = 0, dst = 0;
		while (dst < size) {
			var r = u.execute(raw, src, out, dst);
			src += r.read;
			dst += r.write;
			if (r.done || (r.read == 0 && r.write == 0)) break;
		}
		u.close();
		return out;
		#else
		var i = new haxe.zip.InflateImpl(new haxe.io.BytesInput(raw), false, false);
		var out = Bytes.alloc(size);
		var n = 0;
		while (n < size) {
			var k = i.readBytes(out, n, size - n);
			if (k == 0) break;
			n += k;
		}
		return out;
		#end
	}

	/**
		Null when two HXB archives conform (the same member names, the same
		uncompressed .hxb payloads but for `volatile`), else what differs. With
		`keep`, only the members it accepts count.
	**/
	public static function compareHxb(expected:String, actual:String, ?volatile:Array<String>, ?keep:String->Bool):Null<String> {
		var a, b;
		try {
			a = readZip(expected);
			b = readZip(actual);
		} catch (e:Dynamic) {
			return "unreadable archive: " + Std.string(e);
		}
		if (keep != null) {
			a.names = a.names.filter(keep);
			b.names = b.names.filter(keep);
		}
		var onlyA = [for (n in a.names) if (!b.names.contains(n)) n], onlyB = [for (n in b.names) if (!a.names.contains(n)) n];
		if (onlyA.length > 0 || onlyB.length > 0) {
			onlyA.sort(compare);
			onlyB.sort(compare);
			return 'member set differs (reference-only ${onlyA.length} ${onlyA.slice(0, 3)}, port-only ${onlyB.length} ${onlyB.slice(0, 3)})';
		}
		var names = a.names.copy();
		names.sort(compare);
		var diffs = [];
		for (n in names) {
			if (!n.endsWith(".hxb") || (volatile != null && volatile.contains(n))) continue;
			var x = a.data[n], y = b.data[n];
			if (x.compare(y) != 0) diffs.push(n + "@" + firstDiff(x, y));
		}
		if (diffs.length > 0) return '${diffs.length}/${names.length} payloads differ: ${diffs.slice(0, 4).join(" ")}';
		return null;
	}

	public static function firstDiff(x:Bytes, y:Bytes):Int {
		var n = x.length < y.length ? x.length : y.length;
		for (i in 0...n) if (x.get(i) != y.get(i)) return i;
		return n;
	}

	// command lines

	/** `--name value` and `--flag` options, and the remaining words. **/
	public static function parseArgs(args:Array<String>, withValue:Array<String>):Args {
		var r = new Args();
		var i = 0;
		while (i < args.length) {
			var a = args[i];
			if (a.startsWith("-") && a.length > 1) {
				if (withValue.contains(a)) {
					if (i + 1 >= args.length) throw a + " needs a value";
					r.opts[a] = args[++i];
				} else
					r.opts[a] = "1";
			} else
				r.rest.push(a);
			i++;
		}
		return r;
	}

	public static function fail(msg:String):Dynamic {
		Sys.stderr().writeString(msg + "\n");
		Sys.exit(1);
		return null;
	}

	public static function tail(s:String, n:Int):String return s.length <= n ? s : s.substr(s.length - n);

	/** The lines that differ (a short listing, not a minimal diff). **/
	public static function lineDiff(a:String, b:String, max:Int):Array<String> {
		var la = a.split("\n"), lb = b.split("\n"), out = [];
		var n = la.length > lb.length ? la.length : lb.length;
		for (i in 0...n) {
			var x = la[i], y = lb[i];
			if (x == y) continue;
			if (x != null) out.push('-${i + 1}: $x');
			if (y != null) out.push('+${i + 1}: $y');
			if (out.length >= max) break;
		}
		return out;
	}

	public static function pad(s:String, n:Int):String return s.length >= n ? s : s.rpad(" ", n);

	public static function fixed(v:Float, digits = 1):String {
		var m = Math.pow(10, digits);
		var s = Std.string(Math.round(v * m) / m);
		if (digits > 0 && s.indexOf(".") < 0) s += "." + "".lpad("0", digits);
		return s;
	}

	/** Appends Markdown to the GitHub job summary, when there is one. **/
	public static function summary(path:Null<String>, text:String) {
		if (path == null) path = Sys.getEnv("GITHUB_STEP_SUMMARY");
		if (path == null || path == "") return;
		var o = File.append(path, false);
		o.writeString(text);
		o.close();
	}
}

typedef ExecOptions = {
	?cwd:String,
	?env:Map<String, Null<String>>,
	?log:String,
	?timeout:Float,
	?merge:Bool,
	?stdin:String,
	?inherit:Bool,
}

typedef ExecResult = {
	code:Int,
	out:String,
	err:String,
	seconds:Float,
	timedOut:Bool,
}

class Zip {
	public var names:Array<String> = [];
	public var data:Map<String, Bytes> = [];

	public function new() {}
}

class Args {
	public var opts:Map<String, String> = [];
	public var rest:Array<String> = [];

	public function new() {}

	public function get(k:String, ?def:String):Null<String> return opts.exists(k) ? opts[k] : def;

	public function has(k:String):Bool return opts.exists(k);

	public function int(k:String, def:Int):Int return opts.exists(k) ? Std.parseInt(opts[k]) : def;
}
