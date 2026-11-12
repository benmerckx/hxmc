// Mac Catalyst is checked against its own entry, in iOS's versions, and
// -D hxmc.ios-min-version; macOS's entry does not count there, nor iOS's
// where it has its own. A Platform.supports guard allows what its
// declaration's Catalyst entry allows. (With -D hxmc.strict: errors, at
// typing.)
// target: macos-catalyst-arm64
// define: hxmc.ios-min-version=16.0
// define: hxmc.strict
// expect: Lib.newer: Mac Catalyst 17.0 and later, the deployment target is 16.0 (guard it with Platform.supports(...))
// expect: Lib.newer: Mac Catalyst 17.0 and later, this code is for 16.2 and later
// expect: Lib.mac: Mac Catalyst 16.4 and later, this code is for 16.2 and later
@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available(macos >= 14.0, ios >= 17.0, maccatalyst >= 17.0) static function newer():Int;
	@:hxmc.available(macos >= 99.0, ios >= 15.0, maccatalyst >= 16.4) static function mac():Int;
	@:hxmc.available(macos >= 14.0, ios >= 17.0, maccatalyst >= 16.2) static function older():Int;
}

#if !(maccatalyst >= 16.0) #error "maccatalyst: the deployment target, 16.0" #end
#if (macos || ios) #error "maccatalyst: only its own" #end

class AvailCatalyst {
	static function main() {
		trace(Lib.newer());
		if (hxmc.Platform.supports(Lib.older)) trace(Lib.newer());
		if (hxmc.Platform.supports(Lib.newer)) trace(Lib.newer() + Lib.mac());
		if (hxmc.Platform.supports(Lib.older)) trace(Lib.mac());
	}
}
