import hxmc.Platform;

// Availability (docs/interop.md, "Availability"), built with -D hxmc.strict:
// every use below is allowed. What no system has yet (99.0) is imported
// weakly, so the program launches, and is never reached; a guard the
// deployment target covers folds.
// define: hxmc.strict
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	function init():NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc @:hxmc.available(macos >= 99.0, ios >= 99.0, maccatalyst >= 99.0)
extern class HxmcFuture extends NSObject {
	static function alloc():HxmcFuture;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Sys2 {
	@:hxmc.available(macos >= 99.0, ios >= 99.0, maccatalyst >= 99.0) static function hxmc_future_call():Int;
	@:hxmc.available(macos >= 99.0, ios >= 99.0, maccatalyst >= 99.0) static var hxmc_future_var:Int;
	// (getppid is older; declared newer than the deployment target, it is a weak import that is there)
	@:hxmc.available(macos >= 12.0, ios >= 15.1, maccatalyst >= 15.1) static function getppid():Int;
	// (older than the deployment target: no guard)
	@:hxmc.available(macos >= 10.9, ios >= 9.0, maccatalyst >= 13.1) static function getpid():Int;
}

enum abstract Mode(Int) to Int {
	var Old = 1;
	@:hxmc.available(macos >= 99.0, ios >= 99.0, maccatalyst >= 99.0) var New = 2;
}

class ObjCAvailable {
	// may use what 99.0 has: its callers are checked
	@:hxmc.available(macos >= 99.0, ios >= 99.0, maccatalyst >= 99.0) static function future():Int
		return Sys2.hxmc_future_call() + Sys2.hxmc_future_var + (HxmcFuture.alloc().init() != null ? 1 : 0) + (Mode.New : Int);

	static function early():String {
		if (!Platform.supports(future)) return "early: not yet";
		return "early: " + future();
	}

	static function name(m:Mode):String
		return switch m {
			case Old: "old";
			case New: "new";
			case _: "?";
		}

	static function main() {
		trace(Platform.supports(future), Platform.supports(Sys2.getpid));
		if (Platform.supports(future)) trace(future()) else trace("guarded: not yet");
		trace(early());
		var newer = Platform.supports(Sys2.getppid);
		if (Platform.supports(Sys2.getppid) && Platform.supports(Sys2.getpid)) trace(Sys2.getppid() > 0);
		trace(newer, Sys2.getpid() > 0);
		trace(name(Old), name(cast 2));
		var x = Platform.supports(future) && future() > 0;
		trace(x);
		// (asked again in a loop: the last answer is kept)
		var n = 0;
		for (i in 0...1000)
			if (Platform.supports(Sys2.getppid)) n++;
		trace(n);
		// (a declaration's own versions: its class's, a C function's, an enum constant's)
		if (Platform.supports(HxmcFuture.alloc)) trace(HxmcFuture.alloc().init()) else trace("supports: not yet");
		trace(Platform.supports(HxmcFuture), Platform.supports(Sys2.getppid), Platform.supports(Sys2.getpid), Platform.supports(Mode.New));
	}
}
