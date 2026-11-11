// @:hxmc.available lists string literals of a platform (macos, ios,
// maccatalyst, ...) and a version.
// target: macos-arm64
// expect: @:hxmc.available: a platform and a version ("macos 14.0") as a string literal
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available("macOS 14") static function newer():Int;
}

class AvailBadMeta {
	static function main()
		trace(Lib.newer());
}
