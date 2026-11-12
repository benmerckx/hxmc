// hxmc.Platform.supports names a declaration; it does not call it.
// expect: Platform.supports: a declaration (view.method, a class, a static, an enum constant), not a call
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available(macos >= 14.0) static function newer():Int;
}

class AvailBadSupports {
	static function main()
		trace(hxmc.Platform.supports(Lib.newer()));
}
