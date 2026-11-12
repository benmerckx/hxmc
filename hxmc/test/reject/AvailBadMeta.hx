// @:hxmc.available lists conditions as #if writes them: a platform (macos,
// ios, maccatalyst, ...), >= and a version (a number, or version("x.y.z")).
// The strings of before are none.
// target: macos-arm64
// expect: @:hxmc.available: platforms and versions (macos >= 14.0, ios >= 17.0)
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available("macos 14.0") static function newer():Int;
}

class AvailBadMeta {
	static function main()
		trace(Lib.newer());
}
