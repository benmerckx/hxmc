// Mac Catalyst is checked against its own entry, in iOS's versions, and
// -D hxmc.ios-min-version; macOS's entry does not count there. A guard
// without a Catalyst entry tests iOS's (as Swift's #available).
// target: macos-catalyst-arm64
// define: hxmc.ios-min-version=16.0
// warns: Lib.newer: Mac Catalyst 17.0 and later, the deployment target is 16.0 (guard it with Platform.available("maccatalyst 17.0"))
// warns: Lib.newer: Mac Catalyst 17.0 and later, this code is for 16.2 and later
// warns: Lib.mac: Mac Catalyst 16.4 and later, this code is for 16.2 and later
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available("macos 14.0", "ios 17.0", "maccatalyst 17.0") static function newer():Int;
	@:hxmc.available("macos 99.0", "ios 15.0", "maccatalyst 16.4") static function mac():Int;
}

class AvailCatalyst {
	static function main() {
		trace(Lib.newer());
		// (an older iOS)
		if (hxmc.Platform.available("macos 14.0", "ios 16.2")) trace(Lib.newer());
		if (hxmc.Platform.available("macos 14.0", "ios 17.0")) trace(Lib.newer());
		if (hxmc.Platform.available("maccatalyst 16.2")) trace(Lib.mac());
	}
}
