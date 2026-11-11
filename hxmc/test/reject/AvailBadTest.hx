// hxmc.Platform.available takes string literals: the check and the
// lowering read them.
// expect: hxmc.Platform.available: string literals of a platform and a version ("macos 14.0")
class AvailBadTest {
	static function main() {
		var v = "macos " + Std.random(20) + ".0";
		trace(hxmc.Platform.available(v));
	}
}
