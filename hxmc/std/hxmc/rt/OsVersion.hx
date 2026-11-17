package hxmc.rt;

import hxmc.unsafe.*;

// hxmc.Platform.supports' test at run time (FnLower.available): the
// system's version against a version of the target's platform, asked of
// dyld as clang's __isPlatformVersionAtLeast asks it
// (_availability_version_check, in libSystem since macOS 10.15 and iOS 13,
// below hxmc's floors; it answers a Mac Catalyst process's iOS version), the
// last answer kept: a test in a loop asks dyld once.
@:hxmc.os("macos") @:keep @:allow(hxmc.rt)
class OsVersion {
	// the last version asked << 2 | 2 | the answer (0: none yet): one word,
	// so threads asking at once each read a whole answer
	static var last = 0;

	// platform: PLATFORM_MACOS (1) or PLATFORM_IOS (2: iOS, its simulator, Mac
	// Catalyst); version: major << 16 | minor << 8 | patch, major below 256
	@:hxmc.unsafe @:hxmc.host("rt_os_at_least") static function atLeast(platform:Int, version:Int):Bool {
		var l = last;
		if (l != 0 && l >>> 2 == version) return l & 1 != 0;
		// (dyld_build_version_t: the platform, the version)
		var v = Mem.stack(8);
		Mem.setI32(v, 0, platform);
		Mem.setI32(v, 4, version);
		var yes = Dyld._availability_version_check(1, v) & 0xff != 0;
		last = version << 2 | 2 | (yes ? 1 : 0);
		return yes;
	}
}

@:hxmc.c @:hxmc.fast private extern class Dyld {
	static function _availability_version_check(count:Int, versions:Ptr):Int;
}
