// Round trips of multi-byte strings through child processes under Eval
// (sys.io.Process: haxe/src/macros/eval/EvalProcess.hx over hxmc's host
// processes), many times, the way upstream's sys test (TestUnicode.testIPC)
// runs them once each:
//
//   haxe -cp haxe/test --run IpcStress <haxe binary> [rounds]
//
// The children are the same program, compiled once to HXB and run with
// `--hxb-lib ... --run IpcStress child <mode> ...`. Each round runs every mode:
// - echo: the child prints the line it reads from stdin (the parent reads
//   after the exit code, as runUtility does);
// - nested: the child sets an environment variable and prints what a
//   grandchild prints of it (TestUnicode's putEnv + getEnv / environment);
// - stream: the child writes the string a few bytes at a time, flushing and
//   yielding in between, while the parent reads 1 to 7 bytes at a time
//   (short reads that split UTF-8 sequences; reads that wait for data);
// and once per round the double-close hazard (doubleClose: a process closed
// after its stdin, while another thread reads files that reuse the number).
// Any difference fails with the child's exit code and stderr.
class IpcStress {
	static final STRINGS = [
		"\u{1}", "\u{7F}", "\u{80}", "\u{7FF}", "\u{800}", "\u{D7FF}", "\u{E000}", "\u{FFFD}", "\u{10000}", "\u{1FFFF}", "\u{FFFFF}", "\u{100000}",
		"\u{10FFFF}", "\u{1F602}\u{1F604}\u{1F619}", "\u{227}", "a\u{307}", "\u{4E2D}\u{6587}\u{FF0C}\u{306B}\u{307B}\u{3093}\u{3054}"
	];

	static macro function sourceDir() {
		return macro $v{haxe.io.Path.directory(sys.FileSystem.fullPath(haxe.macro.Context.getPosInfos(haxe.macro.Context.currentPos()).file))};
	}

	static var hxb:String;
	static var bin:String;

	static function main() {
		var args = Sys.args();
		if (args.length == 0) return; // (the HXB build runs main too)
		if (args[0] == "child") {
			child(args.slice(1));
			return;
		}
		bin = args[0];
		var rounds = args.length > 1 ? Std.parseInt(args[1]) : 100;
		var dir = haxe.io.Path.join([Sys.getEnv("IPC_STRESS_DIR") ?? haxe.io.Path.join([sourceDir(), "..", "..", "bin", "test"]), "ipc-stress"]);
		sys.FileSystem.createDirectory(dir);
		hxb = haxe.io.Path.join([dir, "IpcStress.hxb"]);
		if (Sys.command(bin, ["-cp", sourceDir(), "-main", "IpcStress", "--interp", "--hxb", hxb]) != 0)
			throw "could not build " + hxb;
		Sys.putEnv("IPC_STRESS_BIN", bin);
		Sys.putEnv("IPC_STRESS_HXB", hxb);
		var file = haxe.io.Path.join([dir, "content.txt"]), content = STRINGS.join("|");
		sys.io.File.saveContent(file, content);
		var t0 = Sys.time(), fails = 0, runs = 0;
		for (r in 0...rounds) {
			for (i in 0...STRINGS.length) {
				var s = STRINGS[(i + r) % STRINGS.length];
				var long = [for (_ in 0...20) s].join("|");
				for (check in [
					{mode: "echo", expected: s + "\n", res: run(["echo"], s + "\n", false)},
					{mode: "nested", expected: s + "\n", res: run(["nested", s], null, false)},
					{mode: "stream", expected: long, res: run(["stream", long], null, true)}
				]) {
					runs++;
					if (check.res.stdout != check.expected || check.res.exitCode != 0) {
						fails++;
						Sys.println('FAIL round $r ${check.mode}: expected ${codes(check.expected)}, got ${codes(check.res.stdout)}, exit ${check.res.exitCode}, stderr ${haxe.Json.stringify(check.res.stderr)}');
					}
				}
			}
			runs++;
			var err = doubleClose(file, content);
			if (err != null) {
				fails++;
				Sys.println('FAIL round $r double close: $err');
			}
		}
		Sys.println('ipc stress: $runs round trips, $fails failures, ${Math.round(Sys.time() - t0)} s');
		if (fails > 0) Sys.exit(1);
	}

	// The double-close hazard, made deterministic: the parent closes a child's
	// stdin (its number is now free), another thread opens files (one of them
	// gets that number), then the parent closes the process, which must not
	// close stdin again: that would close the other thread's file, whose read
	// then fails (an error that reads as end of file: what an empty stdout in
	// TestUnicode.testIPC would look like). Null: the files read back intact.
	static function doubleClose(file:String, content:String):Null<String> {
		var p = new sys.io.Process(bin, ["--hxb-lib", hxb, "--run", "IpcStress", "child", "drain"]);
		p.stdin.close();
		var opened = new sys.thread.Lock(), closed = new sys.thread.Lock(), done = new sys.thread.Lock();
		var result:Null<String> = null;
		sys.thread.Thread.create(() -> {
			// (more files than the numbers the process left free below its stdin's)
			var inputs = [for (_ in 0...6) sys.io.File.read(file, true)];
			opened.release();
			closed.wait();
			for (k in 0...inputs.length) {
				var got = try inputs[k].readAll().toString() catch (e:Dynamic) 'error: $e';
				try inputs[k].close() catch (_:Dynamic) {}
				if (got != content && result == null) result = 'file $k read back ${haxe.Json.stringify(got)}';
			}
			done.release();
		});
		opened.wait();
		p.exitCode();
		p.close();
		closed.release();
		// (a failed read of the host can end the thread instead of raising in it)
		if (!done.wait(10)) return "the reading thread ended without finishing (a read failed)";
		return result;
	}

	static function codes(s:String):String {
		var a = [for (c in new haxe.iterators.StringIteratorUnicode(s)) c];
		return a.length > 12 ? '${a.length} code points [${a.slice(0, 12).join(",")},...]' : '[${a.join(",")}]';
	}

	static function run(args:Array<String>, stdin:Null<String>, streaming:Bool):{exitCode:Int, stdout:String, stderr:String} {
		var proc = new sys.io.Process(bin, ["--hxb-lib", hxb, "--run", "IpcStress", "child"].concat(args));
		if (stdin != null) {
			proc.stdin.writeString(stdin);
			proc.stdin.flush();
		}
		var stdout;
		var exitCode;
		if (streaming) {
			// reads while the child writes, a few bytes at a time
			var out = new haxe.io.BytesBuffer();
			var buf = haxe.io.Bytes.alloc(7);
			var k = 0;
			try {
				while (true) {
					var n = proc.stdout.readBytes(buf, 0, 1 + (k++ % 7));
					out.addBytes(buf, 0, n);
				}
			} catch (_:haxe.io.Eof) {}
			stdout = out.getBytes().toString();
			exitCode = proc.exitCode();
		} else {
			exitCode = proc.exitCode();
			stdout = proc.stdout.readAll().toString();
		}
		var stderr = proc.stderr.readAll().toString();
		proc.close();
		return {exitCode: exitCode, stdout: stdout, stderr: stderr};
	}

	static function child(args:Array<String>) {
		switch args {
			case ["echo"]:
				Sys.println(Sys.stdin().readLine());
			case ["nested", s]:
				Sys.putEnv("IPC_STRESS", s);
				var p = new sys.io.Process(Sys.getEnv("IPC_STRESS_BIN"), ["--hxb-lib", Sys.getEnv("IPC_STRESS_HXB"), "--run", "IpcStress", "child", "getEnv"]);
				var code = p.exitCode();
				var out = p.stdout.readAll().toString();
				var err = p.stderr.readAll().toString();
				p.close();
				Sys.print(out);
				Sys.stderr().writeString(err);
				Sys.exit(code);
			case ["drain"]:
				Sys.stdin().readAll();
			case ["getEnv"]:
				Sys.println(Sys.getEnv("IPC_STRESS"));
			case ["stream", s]:
				var b = haxe.io.Bytes.ofString(s);
				var out = Sys.stdout();
				var pos = 0, k = 0;
				while (pos < b.length) {
					var n = Std.int(Math.min(1 + (k++ % 5), b.length - pos));
					out.writeBytes(b, pos, n);
					out.flush();
					pos += n;
					if (k % 16 == 0) Sys.sleep(0.001);
				}
			case _:
				throw "unknown child mode " + args;
		}
	}
}
