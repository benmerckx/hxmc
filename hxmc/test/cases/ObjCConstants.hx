import hxmc.objc.AutoreleasePool;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// a framework's C variables (docs/interop.md, "C variables"): constants
// Objective-C declares `extern`, whose values only the framework knows (a
// key's string need not be its name), read through @:hxmc.framework
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	function isEqual(o:NSObject):Bool;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {}

@:hxmc.c @:hxmc.framework("Foundation") extern class FoundationConstants {
	static final NSLocalizedDescriptionKey:NSString;
	static final NSDefaultRunLoopMode:NSString;
	static final NSFoundationVersionNumber:Float;
}

class ObjCConstants {
	static var kept:NSString;

	static function main() AutoreleasePool.run(() -> {
		trace(Strings.ofNSString(cast FoundationConstants.NSLocalizedDescriptionKey), Strings.ofNSString(cast FoundationConstants.NSDefaultRunLoopMode));
		trace(FoundationConstants.NSFoundationVersionNumber > 1000);
		// (the same object each read; held by a static as any id)
		kept = FoundationConstants.NSLocalizedDescriptionKey;
		hxmc.rt.Gc.collect(true);
		trace(kept == FoundationConstants.NSLocalizedDescriptionKey, kept.isEqual(cast Strings.toNSString("NSLocalizedDescription")));
	});
}
