package hxmc.ios;

import haxe.io.Bytes;
import hxmc.ios.Plist;

// An iOS app without Xcode or the SDK (-D hxmc.target=ios-arm64 or
// ios-sim-arm64 and an output ending in .app or .ipa): the bundle
// <name>.app holds the program (LinkMachO's Mach-O, named <name>), its
// Info.plist (XML: the bundle id, the executable, UILaunchScreen as an
// empty dictionary, so the app gets the screen's own size without a
// storyboard; the platform, the minimum version) and
// _CodeSignature/CodeResources (the hashes of the bundle's other files,
// with codesign's default rules); the executable's code signature
// (CodeSign.adhoc, as -D hxmc.codesign-* sign a plain output) is ad hoc,
// identified by the bundle id and binding the Info.plist and CodeResources
// by their hashes, as `codesign -s -` signs: enough for the simulator. A
// .ipa is that bundle under Payload/ in a zip (the executable with its Unix
// mode), for devices later: their
// signature needs a certificate and a provisioning profile
// (CodeSign.Identity; docs/hxmc.md, iOS). Options (Options.ios): -D
// hxmc.ios-bundle-id=<id> (default org.hxmc.<the output's name>), -D
// hxmc.ios-name=<text> (the home screen's label: the output's name), -D
// hxmc.ios-version=<n> (CFBundleVersion, 1), -D
// hxmc.ios-version-name=<text> (CFBundleShortVersionString, 1.0), -D
// hxmc.ios-entitlements=<file> (an XML plist, signed with the code); the
// minimum version is -D hxmc.ios-min-version's (Options.iosMinVersion, as
// for any iOS output).
class Bundle {
	public final name:String; // the bundle's and its executable's
	public final id:String;
	public final info:Bytes;
	public final resources:Bytes;
	public final sign:CodeSign;

	public static function isBundle(out:String):Bool
		return StringTools.endsWith(out, ".app") || StringTools.endsWith(out, ".ipa");

	public function new(out:String, abi:Abi, opts:Map<String, String>, min:String) {
		name = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(out)));
		id = opts.get("bundle_id") ?? "org.hxmc." + ~/[^a-zA-Z0-9.-]/g.replace(name, "-");
		if (!~/^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$/.match(id)) throw "hxmc: iOS: the bundle id " + id + " is not a reverse-DNS name (a.b.c: letters, digits, '-')";
		info = infoPlist(name, id, opts.get("name") ?? name, opts.get("version") ?? "1", opts.get("version_name") ?? "1.0", min, abi.platform == "ios-simulator");
		resources = codeResources(["Info.plist" => info]);
		var ent = opts.get("entitlements");
		sign = CodeSign.adhoc(id, info, resources, ent != null ? sys.io.File.getBytes(ent) : null);
	}

	// the bundle's files (paths in it) around the signed executable
	public function files(exe:Bytes):Array<{path:String, data:Bytes, exec:Bool}>
		return [
			{path: name, data: exe, exec: true},
			{path: "Info.plist", data: info, exec: false},
			{path: "_CodeSignature/CodeResources", data: resources, exec: false}
		];

	// out: <name>.app (a directory, its files replaced) or <name>.ipa
	public function write(out:String, exe:Bytes) {
		var fs = files(exe);
		if (StringTools.endsWith(out, ".ipa")) {
			sys.io.File.saveBytes(out, ipa(fs));
			return;
		}
		var dir = haxe.io.Path.removeTrailingSlashes(out);
		for (f in fs) {
			var p = dir + "/" + f.path;
			sys.FileSystem.createDirectory(haxe.io.Path.directory(p));
			sys.io.File.saveBytes(p, f.data);
			if (f.exec) Driver.markExecutable(p);
		}
	}

	function ipa(fs:Array<{path:String, data:Bytes, exec:Bool}>):Bytes {
		var entries:Array<Zip.ZipEntry> = [];
		for (f in fs)
			entries.push({name: "Payload/" + name + ".app/" + f.path, data: f.data, align: 1, mode: f.exec ? 0x1ed : 0x1a4});
		return Zip.stored(entries);
	}

	public static function infoPlist(exe:String, id:String, label:String, version:String, versionName:String, min:String, simulator:Bool):Bytes {
		var all = PArray([
			PString("UIInterfaceOrientationPortrait"),
			PString("UIInterfaceOrientationPortraitUpsideDown"),
			PString("UIInterfaceOrientationLandscapeLeft"),
			PString("UIInterfaceOrientationLandscapeRight")
		]);
		return Plist.xml(PDict([
			"CFBundleDevelopmentRegion" => PString("en"),
			"CFBundleDisplayName" => PString(label),
			"CFBundleExecutable" => PString(exe),
			"CFBundleIdentifier" => PString(id),
			"CFBundleInfoDictionaryVersion" => PString("6.0"),
			"CFBundleName" => PString(label),
			"CFBundlePackageType" => PString("APPL"),
			"CFBundleShortVersionString" => PString(versionName),
			"CFBundleSupportedPlatforms" => PArray([PString(simulator ? "iPhoneSimulator" : "iPhoneOS")]),
			"CFBundleVersion" => PString(version),
			"DTPlatformName" => PString(simulator ? "iphonesimulator" : "iphoneos"),
			"LSRequiresIPhoneOS" => PBool(true),
			"MinimumOSVersion" => PString(min),
			"UIApplicationSupportsIndirectInputEvents" => PBool(true),
			"UIDeviceFamily" => PArray([PInt(1), PInt(2)]),
			"UILaunchScreen" => PDict([]),
			"UIRequiredDeviceCapabilities" => PArray([PString("arm64")]),
			"UISupportedInterfaceOrientations" => all,
			"UISupportedInterfaceOrientations~ipad" => all
		]));
	}

	// _CodeSignature/CodeResources: each file's SHA-1 (files: the first
	// version's rules) and SHA-1 and SHA-256 (files2), the rules codesign
	// writes for an iOS bundle (Info.plist is in files only: files2's rules
	// omit it, the code signature binds it)
	public static function codeResources(files:Map<String, Bytes>):Bytes {
		function rule(?optional:Bool, ?omit:Bool, weight:Int):PValue {
			var d = ["weight" => PInt(weight)];
			if (optional == true) d.set("optional", PBool(true));
			if (omit == true) d.set("omit", PBool(true));
			return PDict(d);
		}
		var v1 = new Map<String, PValue>(), v2 = new Map<String, PValue>();
		for (path => data in files) {
			v1.set(path, PData(haxe.crypto.Sha1.make(data)));
			if (path != "Info.plist" && path != "PkgInfo")
				v2.set(path, PDict(["hash" => PData(haxe.crypto.Sha1.make(data)), "hash2" => PData(haxe.crypto.Sha256.make(data))]));
		}
		return Plist.xml(PDict([
			"files" => PDict(v1),
			"files2" => PDict(v2),
			"rules" => PDict([
				"^.*" => PBool(true),
				"^.*\\.lproj/" => rule(true, 1000),
				"^.*\\.lproj/locversion.plist$" => rule(false, true, 1100),
				"^Base\\.lproj/" => rule(1010),
				"^version.plist$" => PBool(true)
			]),
			"rules2" => PDict([
				".*\\.dSYM($|/)" => rule(11),
				"^(.*/)?\\.DS_Store$" => rule(false, true, 2000),
				"^.*" => PBool(true),
				"^.*\\.lproj/" => rule(true, 1000),
				"^.*\\.lproj/locversion.plist$" => rule(false, true, 1100),
				"^Base\\.lproj/" => rule(1010),
				"^Info\\.plist$" => rule(false, true, 20),
				"^PkgInfo$" => rule(false, true, 20),
				"^embedded\\.provisionprofile$" => rule(20),
				"^version\\.plist$" => rule(20)
			])
		]));
	}
}
