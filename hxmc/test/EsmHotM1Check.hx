import Harness.*;
import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;

using StringTools;

// M1: file change -> rebuild -> WebSocket patch apply (no manual applyHotPatch): make esm-hot-m1
class EsmHotM1Check {
	static final OUT = "bin/test/esm-hot-m1";
	static final FIXTURE = "hxmc/test/esm/hot/tier1";
	static final PORT = 19876;
	static final SRC = '$OUT/src';
	static final DEV = "hxmc/test/esm/hot/esm-dev.mjs";
	static final CLIENT = "hxmc/test/esm/hot/run-ws-client.mjs";

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? defaultHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		mkdirs(SRC);
		copyFixture();
		if (!compile(haxe, "v1")) Sys.exit(1);
		if (!runWsRoundTrip(haxe)) Sys.exit(1);
		Sys.println("esm-hot-m1: ok");
	}

	static function defaultHaxe():String {
		for (c in ["bin/npm/native/" + Sys.getEnv("HXMC_HOST") + "/haxe", "bin/haxe-js"])
			if (c.indexOf("null") < 0 && FileSystem.exists(c)) return FileSystem.fullPath(c);
		return FileSystem.fullPath("bin/npm/native/macos-arm64/haxe");
	}

	static function copyFixture():Void {
		for (f in FileSystem.readDirectory(FIXTURE)) {
			if (!f.endsWith(".hx")) continue;
			File.copy('$FIXTURE/$f', '$SRC/$f');
		}
	}

	static function compile(haxe:String, label:String):Bool {
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", root + "/" + SRC, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		Sys.println('esm-hot-m1: compile $label');
		var log = '$OUT/$label-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 2000));
			return false;
		}
		if (!FileSystem.exists('$OUT/__hx_hot_manifest.json')) {
			Sys.println("missing __hx_hot_manifest.json");
			return false;
		}
		return true;
	}

	static function compileArgs(haxe:String):Array<String> {
		var js = root + "/" + OUT + "/main.mjs";
		return [haxe, "-cp", root + "/" + SRC, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
	}

	static function runWsRoundTrip(haxe:String):Bool {
		var outAbs = FileSystem.fullPath(OUT);
		var devLog = '$OUT/dev-server.log';
		var devCmd = 'node ${quote(root + "/" + DEV)} --port $PORT --out ${quote(outAbs)} --watch ${quote(root + "/" + SRC)} -- '
			+ [for (a in compileArgs(haxe)) quote(a)].join(" ")
			+ ' >${quote(devLog)} 2>&1 & echo $$! >${quote('$OUT/dev.pid')}';
		var start = exec(["sh", "-c", devCmd], {merge: true});
		if (start.code != 0) {
			Sys.println("esm-dev start failed");
			return false;
		}
		Sys.sleep(0.5);
		var clientLog = '$OUT/client.log';
		var clientPid = '$OUT/client.pid';
		var startClient = 'node ${quote(FileSystem.fullPath(CLIENT))} ${quote(outAbs)} $PORT >${quote(clientLog)} 2>&1 & echo $$! >${quote(clientPid)}';
		if (exec(["sh", "-c", startClient], {merge: true}).code != 0) return false;
		Sys.sleep(2.0);
		var swap = '$SRC/SwapTarget.hx';
		var src = File.getContent(swap);
		File.saveContent(swap, StringTools.replace(src, '"v1"', '"v2"'));
		var clientCode = -1;
		var clientOut = "";
		for (_ in 0...120) {
			Sys.sleep(1.0);
			if (FileSystem.exists(clientLog) && File.getContent(clientLog).indexOf("esm-hot-ws: ok") >= 0) {
				clientCode = 0;
				clientOut = readText(clientLog);
				break;
			}
			var pid = FileSystem.exists(clientPid) ? StringTools.trim(File.getContent(clientPid)) : "";
			if (pid != "" && !pidAlive(pid)) {
				clientCode = 1;
				clientOut = FileSystem.exists(clientLog) ? readText(clientLog) : "";
				break;
			}
		}
		stopDev();
		if (clientCode != 0) {
			Sys.println("WS client failed:\n" + tail(clientOut, 2000));
			if (FileSystem.exists(devLog)) Sys.println(tail(readText(devLog), 1500));
			return false;
		}
		if (!FileSystem.exists('$OUT/__hx_hot_patch.mjs')) {
			Sys.println("missing __hx_hot_patch.mjs after v2 compile");
			return false;
		}
		return true;
	}

	static function stopDev():Void {
		var pidFile = '$OUT/dev.pid';
		if (!FileSystem.exists(pidFile)) return;
		var pid = StringTools.trim(File.getContent(pidFile));
		if (pid == "") return;
		exec(["sh", "-c", 'kill $pid 2>/dev/null || true'], {merge: true});
		try FileSystem.deleteFile(pidFile) catch (_:Dynamic) {}
	}

	static function quote(s:String):String {
		return "'" + StringTools.replace(s, "'", "'\\''") + "'";
	}

	static function pidAlive(pid:String):Bool
		return exec(["sh", "-c", 'kill -0 ${quote(pid)} 2>/dev/null'], {merge: true}).code == 0;
}