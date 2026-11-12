// -D hxmc.strict: a use of a declaration newer than the deployment target,
// unguarded, is an error.
// target: macos-arm64
// define: hxmc.strict
// expect: Lib.newer: macOS 14.0 and later, the deployment target is 11.0 (guard it with Platform.supports(...))
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available(macos >= 14.0, ios >= 17.0) static function newer():Int;
}

class AvailStrict {
	static function main()
		trace(Lib.newer());
}
