import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// File watch, rebuild, WebSocket patch delivery; lane watch-patch of make esm
class EsmHotWatchPatchCheck {
	static final TAG = "hot watch-patch";
	static final OUT = "bin/test/esm/hot/watch-patch";
	static final FIXTURE = "hxmc/test/esm/hot/body-swap";
	static final PORT = 19876;
	static final SRC = '$OUT/src';
	static final DEV = "packages/cli/hxmc/bootstrap/dev.mjs";
	static final CLIENT = "hxmc/test/esm/hot/run-ws-client.mjs";

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		mkdirs(SRC);
		copyFixture();
		if (!compile(haxe, "v1")) Sys.exit(1);
		if (!runWsRoundTrip(haxe)) Sys.exit(1);
		Sys.println('$TAG: ok');
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
		Sys.println('$TAG: compile $label');
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

	static function devDriverArgs(haxe:String):Array<String> {
		var js = root + "/" + OUT + "/main.mjs";
		// `dev.mjs` injects `-D esm.hot` on each resident-server build (docs/plans/esm-dev.md).
		return [haxe, "-cp", root + "/" + SRC, "-main", "Main", "-D", "esm", "-js", js];
	}

	static function runWsRoundTrip(haxe:String):Bool {
		var outAbs = FileSystem.fullPath(OUT);
		var devLog = '$OUT/dev-server.log';
		var driver = devDriverArgs(haxe);
		var devCmd = 'node ${quote(root + "/" + DEV)} ${quote(driver[0])} --port $PORT --quiet '
			+ [for (a in driver.slice(1)) quote(a)].join(" ")
			+ ' >${quote(devLog)} 2>&1 & echo $$! >${quote('$OUT/dev.pid')}';
		var start = exec(["sh", "-c", devCmd], {merge: true, cwd: root});
		if (start.code != 0) {
			Sys.println("esm dev driver start failed");
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
			if (FileSystem.exists(clientLog) && File.getContent(clientLog).indexOf("hot watch-patch: ok") >= 0) {
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