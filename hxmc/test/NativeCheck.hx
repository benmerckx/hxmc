import Harness.*;

// The native output a packager builds on (docs/using.md, "Native output for
// a packager"), each part skipping itself where it cannot run:
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test -cp hxmc/src --run NativeCheck [part [args...]]
//   shared  shared libraries of the glibc mode, Android's .so (SharedCheck)
//   jni     Java through JNI: an embedded JVM, a library Java loads,
//           Android's builds (JniCheck; a JDK, else its runs are skipped)
//   macho   iOS's plain Mach-O executables and dylibs (MachOCheck)
//   uikit   a UIKit app in its bundle (UIKitCheck; a Mac with Xcode)
//   header  the C declarations against each target's headers (HeaderCheck
//           [target...]; zig)
//   elf     the glibc mode's executables in <dir> with readelf (ElfCheck
//           <dir> [--summary <file>])
// No part: all but elf. Exits 1 if one failed.
class NativeCheck {
	static final PARTS:Map<String, Array<String>->Int> = [
		"shared" => SharedCheck.run,
		"jni" => JniCheck.run,
		"macho" => MachOCheck.run,
		"uikit" => UIKitCheck.run,
		"header" => HeaderCheck.run,
		"elf" => ElfCheck.run
	];

	static function main() {
		var args = Sys.args();
		var parts = args.length > 0 ? [args[0]] : ["shared", "jni", "macho", "uikit", "header"];
		var failed = [];
		for (p in parts) {
			var run = PARTS.get(p);
			if (run == null) fail("NativeCheck: no part " + p + " (" + [for (k in PARTS.keys()) k].join(", ") + ")");
			if (run(args.slice(1)) != 0) failed.push(p);
		}
		if (failed.length > 0) fail("NativeCheck: failed: " + failed.join(", "));
	}
}
