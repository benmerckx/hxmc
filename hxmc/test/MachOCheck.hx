import Harness.*;
import haxe.io.Bytes;
import hxmc.MachOReader;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// iOS's native output without a bundle (docs/using.md, "Native output for
// a packager"; make macho-check), checked without a Mac:
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test -cp hxmc/src --run MachOCheck
// hxmc/test/ios/IosHello.hx for ios-arm64, ios-sim-arm64 and Mac Catalyst
// (macos-catalyst-arm64, -x86_64) as a plain executable and as a dylib
// (-D hxmc.shared), each:
// - the Mach-O (MachOReader.commands): 64-bit arm64 (x86-64), MH_EXECUTE (PIE,
//   LC_MAIN, /usr/lib/dyld) or MH_DYLIB (LC_ID_DYLIB @rpath/<name>), the
//   build version's platform (iOS, the simulator, Mac Catalyst), minimum (15.0, or -D
//   hxmc.ios-min-version's) and SDK (26.0, or -D hxmc.ios-sdk-version's),
//   only the system's dylibs, LC_CODE_SIGNATURE at the end of the file and
//   of __LINKEDIT; what ld64 and lld write beside: a device's
//   LC_ENCRYPTION_INFO_64 (cryptoff one page, __text from it, the rest of
//   __TEXT, cryptid 0; none on the simulator and Mac Catalyst),
//   LC_FUNCTION_STARTS (ascending, in __TEXT, the entry point's among
//   them), an empty LC_DATA_IN_CODE;
// - the code signature: the SuperBlob, the CodeDirectory (the page hashes
//   recomputed, the code limit at the signature, __TEXT the executable
//   segment, the main binary's flag only for an executable): linker-signed
//   ad hoc by default (identifier hxmc, no special slots); with -D
//   hxmc.codesign-id, -info-plist, -resources and -entitlements, ad hoc as
//   `codesign -s -` signs, the special slots 1, 3 and 5 the hashes of the
//   files given, 2 the empty requirement set's;
// - UIKit's install name (hxmc/test/cases/ObjCUIKit.hx): iOS's
//   /System/Library/Frameworks, Mac Catalyst's /System/iOSSupport, a
//   framework both share macOS's there;
// - the defines' errors: a minimum or SDK below 15.0, codesign-* on an ELF output;
// - llvm-objdump's view of the load commands, when there.
// Exits non-zero on a failure; a missing tool is skipped.
class MachOCheck {
	static final OUT = "bin/hxmc-macho";
	static var failures:Array<String> = [];

	static function check(what:String, ok:Bool, detail = "") {
		Sys.println(pad(what, 64) + " " + (ok ? "ok" : "FAIL") + (detail != "" ? "  " + detail : ""));
		if (!ok) failures.push(what);
	}

	static function has(tool:String):Bool
		return !windows && exec(["sh", "-c", "command -v " + tool]).code == 0;

	static var tool:String;

	static function build(out:String, args:Array<String>):{ok:Bool, out:String} {
		var r = exec([tool, out, "-cp", "hxmc/test/ios", "-cp", "bin/hxmc/std", "-main", "IosHello", "--custom-target", "hxmc", "-D", "disable-parallelism"].concat(args),
			{merge: true});
		return {ok: r.code == 0, out: r.out};
	}

	static function main() {
		tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		for (t in ["ios-arm64", "ios-sim-arm64", "macos-catalyst-arm64", "macos-catalyst-x86_64"]) {
			var dir = '$OUT/$t';
			mkdirs(dir);
			// the signature's inputs, as a packager writes them before the link
			var info = Bytes.ofString('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.hxmc.macho</string></dict></plist>\n');
			var res = Bytes.ofString('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>files</key><dict/></dict></plist>\n');
			var ent = Bytes.ofString('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>get-task-allow</key><true/></dict></plist>\n');
			File.saveBytes('$dir/Info.plist', info);
			File.saveBytes('$dir/CodeResources', res);
			File.saveBytes('$dir/ent.plist', ent);
			var signed = [
				"-D", "hxmc.codesign-id=org.hxmc.macho",
				"-D", 'hxmc.codesign-info-plist=$dir/Info.plist',
				"-D", 'hxmc.codesign-resources=$dir/CodeResources',
				"-D", 'hxmc.codesign-entitlements=$dir/ent.plist'
			];
			var linker = {id: "hxmc", info: null, res: null, ent: null};
			var bundled = {id: "org.hxmc.macho", info: info, res: res, ent: ent};
			var cases:Array<{name:String, args:Array<String>, dylib:Bool, minos:Int, sign:Expect}> = [
				{name: "IosHello", args: [], dylib: false, minos: 0x000F0000, sign: linker},
				{name: "libIosHello.dylib", args: ["-D", "hxmc.shared"], dylib: true, minos: 0x000F0000, sign: linker},
				{name: "IosHello164", args: ["-D", "hxmc.ios-min-version=16.4"], dylib: false, minos: 0x00100400, sign: linker},
				{name: "IosHelloSdk184", args: ["-D", "hxmc.ios-sdk-version=18.4"], dylib: false, minos: 0x000F0000, sign: linker},
				{name: "IosHelloSigned", args: signed, dylib: false, minos: 0x000F0000, sign: bundled},
				{name: "libIosHelloSigned.dylib", args: signed.concat(["-D", "hxmc.shared", "-D", "hxmc.ios-min-version=17.0"]), dylib: true, minos: 0x00110000, sign: bundled},
				{name: "IosHelloId", args: ["-D", "hxmc.codesign-id=org.hxmc.id"], dylib: false, minos: 0x000F0000, sign: {id: "org.hxmc.id", info: null, res: null, ent: null}}
			];
			for (c in cases) {
				var out = '$dir/${c.name}';
				var r = build(out, c.args.concat(["-D", 'hxmc.target=$t']));
				check('$t ${c.name}: builds', r.ok, r.ok ? "" : tail(r.out, 600));
				if (!r.ok) continue;
				macho('$t ${c.name}', File.getBytes(out), out, t, c.dylib, c.minos, c.args.contains("hxmc.ios-sdk-version=18.4") ? 0x00120400 : 0x001A0000, c.sign);
			}
		}
		// UIKit's install name, and Foundation's beside it
		for (t in ["ios-arm64", "macos-catalyst-arm64"]) {
			var out = '$OUT/$t/ObjCUIKit';
			var r = exec([tool, out, "-cp", "hxmc/test/cases", "-cp", "bin/hxmc/std", "-main", "ObjCUIKit", "--custom-target", "hxmc", "-D", "disable-parallelism",
				"-D", 'hxmc.target=$t'], {merge: true});
			check('$t ObjCUIKit: builds', r.code == 0, r.code == 0 ? "" : tail(r.out, 600));
			if (r.code != 0) continue;
			var b = File.getBytes(out), libs = [];
			for (c in MachOReader.commands(b))
				if (c.cmd == 0xc) libs.push(cstr(b, c.at + b.getInt32(c.at + 8), c.size));
			var uikit = t == "ios-arm64" ? "/System/Library/Frameworks/UIKit.framework/UIKit" : "/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit";
			check('$t ObjCUIKit: UIKit is $uikit', libs.indexOf(uikit) >= 0, libs.join(" "));
			check('$t ObjCUIKit: CoreFoundation is /System/Library/Frameworks\'s', libs.indexOf("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") >= 0, libs.join(" "));
		}
		// the defines' errors
		var r = build('$OUT/bad', ["-D", "hxmc.target=ios-arm64", "-D", "hxmc.ios-min-version=14.0"]);
		check("hxmc.ios-min-version=14.0: an error (15.0 is the floor)", !r.ok && r.out.contains("hxmc.ios-min-version"), r.ok ? "built" : "");
		var r = build('$OUT/bad', ["-D", "hxmc.target=ios-arm64", "-D", "hxmc.ios-sdk-version=26"]);
		check("hxmc.ios-sdk-version=26: an error (major.minor)", !r.ok && r.out.contains("hxmc.ios-sdk-version"), r.ok ? "built" : "");
		var r = build('$OUT/bad', ["-D", "hxmc.target=linux-x86_64", "-D", "hxmc.codesign-id=org.hxmc.x"]);
		check("hxmc.codesign-id on an ELF output: an error", !r.ok && r.out.contains("hxmc.codesign"), r.ok ? "built" : "");
		if (failures.length > 0) {
			Sys.println("MachOCheck: " + failures.length + " failed");
			Sys.exit(1);
		}
		Sys.println("MachOCheck: all passed");
	}

	static function be32(b:Bytes, at:Int):Int
		return (b.get(at) << 24) | (b.get(at + 1) << 16) | (b.get(at + 2) << 8) | b.get(at + 3);

	static function cstr(b:Bytes, at:Int, max:Int):String {
		var e = at;
		while (e < at + max && b.get(e) != 0)
			e++;
		return b.getString(at, e - at);
	}

	static function macho(what:String, b:Bytes, path:String, target:String, dylib:Bool, wantMinos:Int, wantSdk:Int, want:Expect) {
		// (PLATFORM_IOS, PLATFORM_IOSSIMULATOR, PLATFORM_MACCATALYST; llvm-objdump's names)
		var plat = target == "ios-arm64" ? {n: 2, name: "iOS", objdump: "ios"} : target == "ios-sim-arm64" ? {n: 7, name: "iOS simulator", objdump: "iossimulator"} : {
			n: 6, name: "Mac Catalyst", objdump: "macCatalyst"};
		var arm = target.endsWith("arm64");
		check('$what: 64-bit ' + (arm ? "arm64 " : "x86-64 ") + (dylib ? "MH_DYLIB" : "MH_EXECUTE"),
			b.getInt32(0) == 0xfeedfacf && b.getInt32(4) == (arm ? 0x0100000c : 0x01000007) && b.getInt32(12) == (dylib ? 6 : 2));
		var flags = b.getInt32(24);
		check('$what: two-level, dyld' + (dylib ? "" : ", PIE"), flags & 0x84 == 0x84 && (dylib || flags & 0x200000 != 0));
		var platform = -1, minos = -1, sdk = -1, main = false, dyld = "", id = "", libs = [], sigOff = -1, sigSize = 0;
		var textFileSize = 0, leEnd = 0, textSect = -1, entry = -1;
		var crypt:Null<{off:Int, size:Int, id:Int}> = null, starts:Null<{off:Int, size:Int}> = null, dic:Null<{off:Int, size:Int}> = null;
		for (c in MachOReader.commands(b)) {
			var at = c.at;
			switch c.cmd {
				case 0x32:
					platform = b.getInt32(at + 8);
					minos = b.getInt32(at + 12);
					sdk = b.getInt32(at + 16);
				case 0x80000028:
					main = true;
					entry = b.getInt32(at + 8);
				case 0x2c: crypt = {off: b.getInt32(at + 8), size: b.getInt32(at + 12), id: b.getInt32(at + 16)};
				case 0x26: starts = {off: b.getInt32(at + 8), size: b.getInt32(at + 12)};
				case 0x29: dic = {off: b.getInt32(at + 8), size: b.getInt32(at + 12)};
				case 0xe: dyld = cstr(b, at + b.getInt32(at + 8), c.size);
				case 0xd: id = cstr(b, at + b.getInt32(at + 8), c.size);
				case 0xc: libs.push(cstr(b, at + b.getInt32(at + 8), c.size));
				case 0x1d:
					sigOff = b.getInt32(at + 8);
					sigSize = b.getInt32(at + 12);
				case 0x19:
					var name = cstr(b, at + 8, 16);
					var fileoff = b.getInt32(at + 40), filesize = b.getInt32(at + 48);
					if (name == "__TEXT") {
						textFileSize = filesize;
						for (k in 0...b.getInt32(at + 64))
							if (cstr(b, at + 72 + 80 * k, 16) == "__text") textSect = b.getInt32(at + 72 + 80 * k + 48);
					}
					if (name == "__LINKEDIT") leEnd = fileoff + filesize;
				case _:
			}
		}
		check('$what: the build version: ${plat.name} (${plat.n}), SDK ' + (wantSdk >> 16) + "." + ((wantSdk >> 8) & 0xff), platform == plat.n && sdk == wantSdk,
			platform + " " + StringTools.hex(sdk));
		if (target == "ios-arm64")
			check('$what: LC_ENCRYPTION_INFO_64: __TEXT after its first page, __text from there, cryptid 0',
				crypt != null && crypt.off == 0x4000 && crypt.size == textFileSize - 0x4000 && crypt.id == 0 && textSect == 0x4000,
				crypt == null ? "none" : StringTools.hex(crypt.off) + " " + StringTools.hex(crypt.size) + " __text at " + StringTools.hex(textSect));
		else check('$what: no LC_ENCRYPTION_INFO_64', crypt == null);
		var fs = [];
		if (starts != null) {
			var k = starts.off, a = 0;
			while (k < starts.off + starts.size && b.get(k) != 0) {
				var v = 0, sh = 0, byte;
				do {
					byte = b.get(k++);
					v |= (byte & 0x7f) << sh;
					sh += 7;
				} while (byte & 0x80 != 0);
				a += v;
				fs.push(a);
			}
		}
		check('$what: LC_FUNCTION_STARTS: ascending, in __TEXT' + (dylib ? "" : ", the entry point among them"),
			starts != null && fs.length > 0 && fs[0] >= textSect && fs[fs.length - 1] < textFileSize && (dylib || fs.contains(entry)),
			starts == null ? "none" : fs.length + " functions");
		check('$what: LC_DATA_IN_CODE, empty', dic != null && dic.size == 0);
		check('$what: the build version\'s minimum ' + (wantMinos >> 16) + "." + ((wantMinos >> 8) & 0xff), minos == wantMinos, StringTools.hex(minos));
		if (dylib) check('$what: LC_ID_DYLIB @rpath/<name>, no LC_MAIN', !main && id == "@rpath/" + haxe.io.Path.withoutDirectory(path), id);
		else check('$what: LC_MAIN, /usr/lib/dyld', main && dyld == "/usr/lib/dyld");
		check('$what: libSystem first, only the system\'s dylibs', libs[0] == "/usr/lib/libSystem.B.dylib"
			&& Lambda.foreach(libs, l -> l.startsWith("/usr/lib/") || l.startsWith("/System/Library/Frameworks/")),
			libs.map(l -> haxe.io.Path.withoutDirectory(l)).join(" "));
		check('$what: the signature ends the file and __LINKEDIT', sigOff > 0 && sigOff + sigSize == b.length && leEnd == b.length);
		if (sigOff > 0) signature(what, b, sigOff, textFileSize, !dylib, want);
		if (has("llvm-objdump")) {
			var r = exec(["llvm-objdump", "--macho", "--private-headers", path], {merge: true});
			check('$what: llvm-objdump reads the load commands', r.code == 0 && r.out.indexOf("platform " + plat.objdump + "\n") >= 0,
				r.code == 0 ? "" : tail(r.out, 200));
		}
	}

	static function signature(what:String, b:Bytes, sigOff:Int, textFileSize:Int, mainBinary:Bool, want:Expect) {
		var linker = want.id == "hxmc";
		check('$what: signature: a SuperBlob', be32(b, sigOff) == 0xfade0cc0);
		var count = be32(b, sigOff + 8);
		var blobs = new Map<Int, Int>();
		for (k in 0...count)
			blobs.set(be32(b, sigOff + 12 + 8 * k), sigOff + be32(b, sigOff + 16 + 8 * k));
		var cd = blobs.get(0), req = blobs.get(2), ent = blobs.get(5);
		check('$what: signature: a CodeDirectory', cd != null && be32(b, cd) == 0xfade0c02);
		if (cd == null) return;
		var cdFlags = be32(b, cd + 12), hashOff = be32(b, cd + 16), identOff = be32(b, cd + 20), nSpecial = be32(b, cd + 24), nCode = be32(b, cd + 28),
			codeLimit = be32(b, cd + 32), hashSize = b.get(cd + 36), hashType = b.get(cd + 37), pageLog = b.get(cd + 39);
		var ident = cstr(b, cd + identOff, 256);
		check('$what: CodeDirectory: identifier ' + want.id, ident == want.id, ident);
		check('$what: CodeDirectory: SHA-256 of 4 KB pages up to the signature', hashSize == 32 && hashType == 2 && pageLog == 12 && codeLimit == sigOff
			&& nCode == (codeLimit + 4095) >> 12);
		// (execSegBase, execSegLimit, execSegFlags: 64-bit words at 64, 72, 80)
		check('$what: CodeDirectory: __TEXT the executable segment' + (mainBinary ? ", the main binary" : ", not a main binary"),
			be32(b, cd + 64) == 0 && be32(b, cd + 68) == 0 && be32(b, cd + 72) == 0 && be32(b, cd + 76) == textFileSize
			&& be32(b, cd + 84) & 1 == (mainBinary ? 1 : 0));
		var bad = 0;
		for (k in 0...nCode) {
			var off = k << 12, n = codeLimit - off < 4096 ? codeLimit - off : 4096;
			if (haxe.crypto.Sha256.make(b.sub(off, n)).toHex() != b.sub(cd + hashOff + 32 * k, 32).toHex()) bad++;
		}
		check('$what: CodeDirectory: the page hashes', bad == 0, bad + " of " + nCode + " differ");
		if (linker) {
			check('$what: linker-signed ad hoc, the CodeDirectory alone', cdFlags == 0x20002 && count == 1 && nSpecial == 0,
				StringTools.hex(cdFlags) + " " + count + " blobs, " + nSpecial + " special slots");
			return;
		}
		check('$what: ad hoc, not linker-signed', cdFlags == 0x2, StringTools.hex(cdFlags));
		check('$what: an empty requirement set', req != null && be32(b, req) == 0xfade0c01 && be32(b, req + 4) == 12 && be32(b, req + 8) == 0);
		var slots = want.ent != null ? 5 : want.res != null ? 3 : 2;
		check('$what: $slots special slots', nSpecial == slots, "" + nSpecial);
		function slot(k:Int):String
			return k > nSpecial ? "" : b.sub(cd + hashOff - 32 * k, 32).toHex();
		var zero = Bytes.alloc(32);
		zero.fill(0, 32, 0);
		function hash(d:Null<Bytes>):String
			return d == null ? zero.toHex() : haxe.crypto.Sha256.make(d).toHex();
		check('$what: slot 1 is the Info.plist\'s hash', slot(1) == hash(want.info));
		if (req != null) check('$what: slot 2 is the requirements\' hash', slot(2) == hash(b.sub(req, be32(b, req + 4))));
		if (slots >= 3) check('$what: slot 3 is CodeResources\' hash', slot(3) == hash(want.res));
		if (want.ent != null) {
			check('$what: the entitlements blob holds the file', ent != null && be32(b, ent) == 0xfade7171 && be32(b, ent + 4) == 8 + want.ent.length
				&& b.sub(ent + 8, want.ent.length).compare(want.ent) == 0);
			if (ent != null) check('$what: slot 5 is the entitlements blob\'s hash', slot(5) == hash(b.sub(ent, be32(b, ent + 4))));
		} else check('$what: no entitlements', ent == null);
	}
}

typedef Expect = {id:String, info:Null<Bytes>, res:Null<Bytes>, ent:Null<Bytes>};
