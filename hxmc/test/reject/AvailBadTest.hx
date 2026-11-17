// hxmc.Platform.supports names a declaration, not a value: a local holding
// a function has no @:hxmc.available to read. (Platform.available, a test of
// versions, is not in hxmc.Platform.)
// expect: Platform.supports: a declaration (view.method, a class, a static, an enum constant)
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available(macos >= 14.0) static function newer():Int;
}

class AvailBadTest {
	static function main() {
		var f = Lib.newer;
		trace(hxmc.Platform.supports(f));
	}
}
