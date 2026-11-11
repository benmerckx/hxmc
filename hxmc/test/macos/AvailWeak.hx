import hxmc.Platform;

// MachOCheck's macOS program (-D hxmc.strict): what no system has yet
// (99.0) is imported weakly and guarded; getppid, declared 12.0's, is a
// strong import with -D hxmc.macos-min-version=12.0 and needs no guard there.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	function init():NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc @:hxmc.available("macos 99.0")
extern class HxmcFuture extends NSObject {
	static function alloc():HxmcFuture;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available("macos 99.0") static function hxmc_future_call():Int;
	@:hxmc.available("macos 99.0") static var hxmc_future_var:Int;
	@:hxmc.available("macos 12.0") static function getppid():Int;
}

class AvailWeak {
	static function main() {
		trace(Lib.getppid() > 0);
		if (Platform.available("macos 99.0")) trace(Lib.hxmc_future_call() + Lib.hxmc_future_var, HxmcFuture.alloc().init());
	}
}
