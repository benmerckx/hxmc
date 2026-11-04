import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// A UIKit app in its bundle, run (make uikit-check; a Mac with Xcode):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run UIKitCheck
// (CI: @hxmc/cli's compiler, HXMC_TOOL=<it>, on macOS arm64 and x86-64)
// hxmc/test/ios/UIKitHello.hx (its own hxmc_ui_main: UIApplicationMain, a
// Haxe delegate, the program's body once launched) bundled as a packager
// would, signed binding the Info.plist (-D hxmc.codesign-*), then:
// - Mac Catalyst (the host's architecture): the .app's executable run; an
//   agent app (LSUIElement), as a managed Mac may end a regular one that
//   is not its administrator's;
// - the iOS simulator, an iPhone and an iPad (the newest iOS runtime's
//   first of each): booted (simctl bootstatus -b), installed, launched
//   (the app's stdout and stderr in files), uninstalled; a launch the app
//   did not start in (a cold device on a hosted runner) is retried after a
//   reboot (and an erase, for a device booted here), twice; a device booted here is shut down after.
// Each prints what the app saw: the delegate called, the body run after it,
// the window key and sized, the label's text. Exits non-zero on a failure;
// no Xcode (or not macOS): skipped.
class UIKitCheck {
	static final OUT = "bin/hxmc-uikit";
	static final ID = "org.hxmc.uikithello";
	static final EXPECTED = ["launched", "main", "window key true, bounds true, label hello from hxmc"];
	static var failures:Array<String> = [];
	static var tool:String;

	static function check(what:String, ok:Bool, detail = "") {
		Sys.println(pad(what, 48) + " " + (ok ? "ok" : "FAIL") + (detail != "" ? "  " + detail : ""));
		if (!ok) failures.push(what);
	}

	static function plist(entries:String):String
		return '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
			+ '<plist version="1.0"><dict>\n<key>CFBundleIdentifier</key><string>$ID</string>\n<key>CFBundleExecutable</key><string>UIKitHello</string>\n'
			+ '<key>CFBundleName</key><string>UIKitHello</string>\n<key>CFBundlePackageType</key><string>APPL</string>\n'
			+ '<key>CFBundleVersion</key><string>1</string>\n<key>CFBundleShortVersionString</key><string>1.0</string>\n$entries</dict></plist>\n';

	// the executable linked into dir (the Info.plist written there first: the signature binds it)
	static function build(target:String, info:String, exe:String):Bool {
		// (an installed compiler: its own std)
		var std = FileSystem.exists("bin/hxmc/std") ? ["-cp", "bin/hxmc/std"] : [];
		var r = exec([tool, "-cp", "hxmc/test/ios"].concat(std).concat(["-main", "UIKitHello", "-D", 'hxmc.target=$target', "-D", "disable-parallelism",
			"-D", 'hxmc.codesign-id=$ID', "-D", 'hxmc.codesign-info-plist=$info', "--custom-target", 'hxmc=$exe']), {merge: true});
		check('$target: build', r.code == 0, r.code == 0 ? "" : tail(r.out, 400));
		return r.code == 0;
	}

	static function output(what:String, code:Int, out:String) {
		var missing = [for (l in EXPECTED) if (out.indexOf(l) < 0) l];
		check(what, code == 0 && missing.length == 0, code == 0 && missing.length == 0 ? EXPECTED[2] : 'exit $code, missing ${missing}: ' + tail(out, 400));
	}

	static function dir(target:String):String {
		mkdirs('$OUT/$target');
		return FileSystem.fullPath('$OUT/$target');
	}

	static function catalyst(target:String) {
		var app = dir(target) + '/UIKitHello.app';
		rmrf(app);
		mkdirs('$app/Contents/MacOS');
		File.saveContent('$app/Contents/Info.plist', plist('<key>LSUIElement</key><true/>\n'));
		if (!build(target, '$app/Contents/Info.plist', '$app/Contents/MacOS/UIKitHello')) return;
		var r = exec(['$app/Contents/MacOS/UIKitHello'], {merge: true, timeout: 60});
		output('$target: the app', r.code, r.out);
	}

	// the newest iOS runtime's first available device whose name starts so
	static function device(family:String):Null<{udid:String, name:String, state:String}> {
		var r = exec(["xcrun", "simctl", "list", "devices", "available", "--json"]);
		if (r.code != 0) return null;
		var devices:haxe.DynamicAccess<Array<{udid:String, name:String, state:String}>> = haxe.Json.parse(r.out).devices;
		var runtimes = [for (k in devices.keys()) if (k.indexOf("SimRuntime.iOS") >= 0) k];
		runtimes.sort(Reflect.compare);
		runtimes.reverse();
		for (k in runtimes)
			for (d in devices[k])
				if (d.name.startsWith(family)) return d;
		return null;
	}

	static inline final SIM = "ios-sim-arm64";
	// launches on a device: the first and two more, each after a reboot (and
	// an erase, for a device this check booted: a reboot alone has left
	// simctl's launch stuck again), while the device's time is under BUDGET
	// seconds
	static inline final ATTEMPTS = 3;
	static inline final BUDGET = 720;

	static function note(what:String, text:String)
		Sys.println(pad('$SIM: $what', 48) + " " + text);

	static function secs(t0:Float):String
		return Std.int(now() - t0) + "s";

	// booted (fully: bootstatus -b waits for the boot to finish) and the app
	// installed (simctl install returns once it is); null, or why not
	static function ready(d:{udid:String, name:String}):Null<String> {
		var t0 = now();
		var b = exec(["xcrun", "simctl", "bootstatus", d.udid, "-b"], {timeout: 300});
		if (b.code != 0) return 'bootstatus: exit ${b.code} after ${secs(t0)}: ' + tail(b.out + b.err, 400);
		var t1 = now();
		var i = exec(["xcrun", "simctl", "install", d.udid, app], {timeout: 120});
		// (a device just shut down and booted again may refuse the first install: once more)
		if (i.code != 0) {
			note('${d.name}', 'install: exit ${i.code}, once more: ' + tail(i.err + i.out, 300));
			exec(["xcrun", "simctl", "bootstatus", d.udid, "-b"], {timeout: 300});
			i = exec(["xcrun", "simctl", "install", d.udid, app], {timeout: 120});
		}
		if (i.code != 0) return 'install: exit ${i.code}: ' + tail(i.err + i.out, 400);
		note('${d.name}', 'booted in ${Std.int(t1 - t0)}s, installed in ${secs(t1)}');
		return null;
	}

	// a reboot; erased too when asked (shut down, the only state erase takes)
	static function reset(d:{udid:String, name:String}, erase:Bool) {
		exec(["xcrun", "simctl", "terminate", d.udid, ID], {timeout: 30});
		exec(["xcrun", "simctl", "shutdown", d.udid], {timeout: 120});
		if (erase) exec(["xcrun", "simctl", "erase", d.udid], {timeout: 120});
		exec(["xcrun", "simctl", "boot", d.udid], {timeout: 120});
	}

	// what the device and the app were doing: printed on a failure
	static function diagnose(d:{udid:String, name:String}, since:Float) {
		var state = exec(["xcrun", "simctl", "list", "devices"], {timeout: 30});
		note('${d.name}', "device: " + [for (l in state.out.split("\n")) if (l.indexOf(d.udid) >= 0) l.trim()].join("; "));
		var b = exec(["xcrun", "simctl", "bootstatus", d.udid], {timeout: 30});
		note('${d.name}', 'bootstatus: exit ${b.code}: ' + tail((b.out + b.err).trim(), 300));
		var minutes = Std.int((now() - since) / 60) + 2;
		var log = exec(["xcrun", "simctl", "spawn", d.udid, "log", "show", "--style", "compact", "--last", '${minutes}m', "--predicate",
			'process == "UIKitHello" OR eventMessage CONTAINS[c] "uikithello"'], {timeout: 120});
		note('${d.name}', 'log (exit ${log.code}):\n' + tail(log.out + log.err, 3000));
		var reports = '${Sys.getEnv("HOME")}/Library/Logs/DiagnosticReports';
		var crashes = try [for (f in FileSystem.readDirectory(reports)) if (f.startsWith("UIKitHello")) f] catch (_:Dynamic) [];
		crashes.sort(Reflect.compare);
		if (crashes.length > 0) note('${d.name}', 'crash report ${crashes[crashes.length - 1]}:\n' + readText('$reports/${crashes[crashes.length - 1]}').substr(0, 3000));
	}

	static var app:String;

	// the app launched once, its stdout and stderr in files (the simulator's
	// processes write the host's files; simctl's own console relay may return
	// before the app's last line is through); what it printed, simctl's
	// result, and whether the app is known to have started
	static function launch(d:{udid:String, name:String}, attempt:Int):{out:String, simctl:Harness.ExecResult, started:Bool} {
		var base = dir(SIM) + '/${d.udid}-$attempt';
		for (f in ['$base.out', '$base.err']) if (FileSystem.exists(f)) FileSystem.deleteFile(f);
		var t0 = now();
		var r = exec(["xcrun", "simctl", "launch", "--terminate-running-process", '--stdout=$base.out', '--stderr=$base.err', d.udid, ID], {timeout: 90});
		// the app prints its lines and exits: when it has ended before simctl
		// finished launching it, simctl reports "The process did launch, but
		// has since exited or crashed" (FBSOpenApplicationServiceErrorDomain
		// code 3); what it printed decides then (hxmc/test/ios/ios.sh did so)
		var started = r.code == 0 || (r.out + r.err).indexOf("did launch") >= 0;
		var out = "";
		var deadline = now() + 60;
		do {
			out = readText('$base.out') + readText('$base.err');
			if (out.indexOf(EXPECTED[2]) >= 0) break;
			Sys.sleep(1);
		} while (started && now() < deadline);
		note('${d.name}', 'launch ${attempt + 1}: simctl exit ${r.code}${r.timedOut ? " (timed out)" : ""} in ${Std.int(r.seconds)}s, output after ${secs(t0)}'
			+ ((r.code != 0 || out.indexOf(EXPECTED[2]) < 0) ? ": simctl said " + tail((r.out + r.err).trim(), 600) : ""));
		return {out: out, simctl: r, started: started || out != ""};
	}

	static function simulator() {
		app = dir(SIM) + '/UIKitHello.app';
		rmrf(app);
		mkdirs(app);
		File.saveContent('$app/Info.plist', plist('<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>\n'
			+ '<key>MinimumOSVersion</key><string>15.0</string>\n<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>\n'
			+ '<key>UILaunchScreen</key><dict/>\n'));
		if (!build(SIM, '$app/Info.plist', '$app/UIKitHello')) return;
		for (family in ["iPhone", "iPad"]) {
			var d = device(family);
			if (d == null) {
				Sys.println(pad('$SIM $family', 48) + " skipped (no such simulator)");
				continue;
			}
			var t0 = now();
			var booted = d.state != "Booted";
			if (booted) exec(["xcrun", "simctl", "boot", d.udid], {timeout: 120});
			// a launch is retried only when the app did not start: the device not
			// ready (a cold boot on a hosted runner), simctl's launch refused or
			// stuck. An app that started and then failed, crashed or hung fails.
			var result:Null<{out:String, simctl:Harness.ExecResult, started:Bool}> = null;
			var why = "";
			for (attempt in 0...ATTEMPTS) {
				if (attempt > 0) {
					if (now() - t0 > BUDGET) break;
					var erase = booted;
					note('${d.name}', 'retrying after ${erase ? "erasing and " : ""}rebooting the device ($why)');
					diagnose(d, t0);
					reset(d, erase);
				}
				var notReady = ready(d);
				if (notReady != null) {
					why = notReady;
					result = null;
					continue;
				}
				result = launch(d, attempt);
				if (result.started) break;
				why = 'the app did not start, simctl exit ${result.simctl.code}${result.simctl.timedOut ? " (timed out)" : ""}';
			}
			if (result == null) check('$SIM: ${d.name}: install', false, why);
			else {
				var r = result;
				output('$SIM: ${d.name}', r.started ? 0 : r.simctl.code, r.out);
				if (!r.started || [for (l in EXPECTED) if (r.out.indexOf(l) < 0) l].length > 0) diagnose(d, t0);
			}
			exec(["xcrun", "simctl", "terminate", d.udid, ID], {timeout: 30});
			exec(["xcrun", "simctl", "uninstall", d.udid, ID], {timeout: 60});
			if (booted) exec(["xcrun", "simctl", "shutdown", d.udid], {timeout: 120});
			note('${d.name}', 'done in ${secs(t0)}');
		}
	}

	static function main() {
		if (Sys.systemName() != "Mac" || exec(["xcrun", "--find", "simctl"]).code != 0) {
			Sys.println("uikit-check: skipped (not a Mac with Xcode)");
			return;
		}
		tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		var arm = exec(["uname", "-m"]).out.trim() == "arm64";
		catalyst(arm ? "macos-catalyst-arm64" : "macos-catalyst-x86_64");
		if (arm) simulator();
		if (failures.length > 0) {
			Sys.println('uikit-check: ${failures.length} failed: ${failures.join(", ")}');
			Sys.exit(1);
		}
		Sys.println("uikit-check: ok");
	}
}
