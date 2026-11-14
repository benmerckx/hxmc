import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// A UIKit app in its bundle, run (node make.mjs native-check NATIVE=uikit; a Mac with Xcode):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test -cp hxmc/src --run NativeCheck uikit
// (CI: @hxmc/cli's compiler, HXMC_TOOL=<it>, on macOS arm64 and x86-64)
// hxmc/test/ios/UIKitHello.hx (its own hxmc_ui_main: UIApplicationMain, a
// Haxe delegate, the program's body once launched) bundled as a packager
// would, signed binding the Info.plist (-D hxmc.codesign-*), then:
// - Mac Catalyst (the host's architecture): the .app's executable run; an
//   agent app (LSUIElement), as a managed Mac may end a regular one that
//   is not its administrator's;
// - the iOS simulator, an iPhone and an iPad (the newest iOS runtime's
//   first of each; on CI, CI set, the iPhone only: the same binary on the
//   same runtime, the iPad one more boot, one more chance for a hosted
//   runner's simulator to stall): installed, launched (simctl launch, its
//   output to files: --console-pty, on a hosted runner, at times lost what
//   the app printed last, or never connected), uninstalled; a device booted
//   here is shut down after. A launch that printed nothing is tried once
//   more on the device booted again, on CI erased first (a stalled launch
//   recovered only so, #151); a failed one prints the app's log.
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

	// the app launched on the device, its output (stdout and stderr) read until the
	// last expected line or until `seconds` pass; the code: simctl launch's, or -1
	// for a timeout
	static function launch(udid:String, seconds:Float):{code:Int, out:String} {
		var base = dir("ios-sim-arm64") + '/console-$udid';
		for (f in ['$base.out', '$base.err']) if (FileSystem.exists(f)) FileSystem.deleteFile(f);
		var l = exec(["xcrun", "simctl", "launch", "--terminate-running-process", '--stdout=$base.out', '--stderr=$base.err', udid, ID],
			{merge: true, timeout: 120});
		if (l.code != 0) return {code: l.code, out: l.out};
		var deadline = now() + seconds;
		while (true) {
			var out = readText('$base.out') + readText('$base.err');
			if (out.indexOf(EXPECTED[EXPECTED.length - 1]) >= 0) return {code: 0, out: out};
			if (now() > deadline) return {code: -1, out: out};
			Sys.sleep(0.25);
		}
	}

	static function simulator() {
		var app = dir("ios-sim-arm64") + '/UIKitHello.app';
		rmrf(app);
		mkdirs(app);
		File.saveContent('$app/Info.plist', plist('<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>\n'
			+ '<key>MinimumOSVersion</key><string>15.0</string>\n<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>\n'
			+ '<key>UILaunchScreen</key><dict/>\n'));
		if (!build("ios-sim-arm64", '$app/Info.plist', '$app/UIKitHello')) return;
		var ci = Sys.getEnv("CI") != null && Sys.getEnv("CI") != "";
		for (family in (ci ? ["iPhone"] : ["iPhone", "iPad"])) {
			var d = device(family);
			if (d == null) {
				Sys.println(pad('ios-sim-arm64 $family', 48) + " skipped (no such simulator)");
				continue;
			}
			var booted = d.state != "Booted";
			if (booted) exec(["xcrun", "simctl", "boot", d.udid]);
			exec(["xcrun", "simctl", "bootstatus", d.udid, "-b"], {timeout: 300});
			function install() {
				var i = exec(["xcrun", "simctl", "install", d.udid, app], {merge: true, timeout: 120});
				// (a device just shut down and booted again may refuse the first install: once more)
				if (i.code != 0) {
					exec(["xcrun", "simctl", "bootstatus", d.udid, "-b"], {timeout: 300});
					i = exec(["xcrun", "simctl", "install", d.udid, app], {merge: true, timeout: 120});
				}
				return i;
			}
			var i = install();
			if (i.code != 0) check('ios-sim-arm64: ${d.name}: install', false, tail(i.out, 400));
			else {
				var r = launch(d.udid, 120);
				// (a hosted runner's simulator may not run the app at all: once more, the
				// device booted again)
				if (r.code != 0 && r.out.indexOf("launched") < 0) {
					Sys.println(pad('ios-sim-arm64: ${d.name}', 48) + ' retrying the launch (exit ${r.code}, nothing printed)' + (ci ? ", the device erased" : ""));
					exec(["xcrun", "simctl", "shutdown", d.udid], {timeout: 120});
					// (not a local device: what a user keeps in it)
					if (ci) exec(["xcrun", "simctl", "erase", d.udid], {timeout: 120});
					exec(["xcrun", "simctl", "boot", d.udid], {timeout: 120});
					exec(["xcrun", "simctl", "bootstatus", d.udid, "-b"], {timeout: 300});
					var i2 = install();
					r = i2.code == 0 ? launch(d.udid, 120) : {code: i2.code, out: i2.out};
				}
				if (r.code != 0) {
					// (what the device logged of the app: why it printed nothing)
					var log = exec(["xcrun", "simctl", "spawn", d.udid, "log", "show", "--last", "5m", "--style", "compact", "--predicate",
						'process == "UIKitHello" OR eventMessage CONTAINS "$ID"'], {merge: true, timeout: 120});
					Sys.println('ios-sim-arm64: ${d.name}: the app\'s log (last lines):\n' + tail(log.out, 4000));
				}
				output('ios-sim-arm64: ${d.name}', r.code, r.out);
				exec(["xcrun", "simctl", "uninstall", d.udid, ID]);
			}
			if (booted) exec(["xcrun", "simctl", "shutdown", d.udid]);
		}
	}

	public static function run(args:Array<String>):Int {
		if (Sys.systemName() != "Mac" || exec(["xcrun", "--find", "simctl"]).code != 0) {
			Sys.println("UIKitCheck: skipped (not a Mac with Xcode)");
			return 0;
		}
		tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		var arm = exec(["uname", "-m"]).out.trim() == "arm64";
		catalyst(arm ? "macos-catalyst-arm64" : "macos-catalyst-x86_64");
		if (arm) simulator();
		if (failures.length > 0) {
			Sys.println('UIKitCheck: ${failures.length} failed: ${failures.join(", ")}');
			return 1;
		}
		Sys.println("UIKitCheck: ok");
		return 0;
	}
}
