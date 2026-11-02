import hxmc.objc.AutoreleasePool;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// variadic messages (docs/interop.md, "Calls"): a method's `...rest`
// arguments passed as a variadic function's (on Apple's arm64, on the
// stack), its fixed ones as any; @:hxmc.nilTerminated appends nil
// (NS_REQUIRES_NIL_TERMINATION): lists past the registers, empty ones, a
// format's objects.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements hxmc.objc.Id {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function stringWithFormat(format:NSString, ...args:NSObject):NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	@:hxmc.nilTerminated static function arrayWithObjects(firstObj:Null<NSObject>, ...rest:NSObject):NSArray;
	function count():Int64;
	function componentsJoinedByString(separator:NSString):NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSDictionary extends NSObject {
	@:hxmc.nilTerminated static function dictionaryWithObjectsAndKeys(firstObject:Null<NSObject>, ...rest:NSObject):NSDictionary;
	function objectForKey(key:NSObject):Null<NSObject>;
	function count():Int64;
}

class ObjCVariadic {
	static function ns(s:String):NSString
		return cast Strings.toNSString(s);

	static function str(s:NSString):String
		return Strings.ofNSString(cast s);

	static function main() AutoreleasePool.run(() -> {
		var three = NSArray.arrayWithObjects(ns("a"), ns("b"), ns("c"));
		trace("three", three.count().toInt(), str(three.componentsJoinedByString(ns(","))));
		var one = NSArray.arrayWithObjects(ns("only"));
		trace("one", one.count().toInt(), str(one.componentsJoinedByString(ns(","))));
		var none = NSArray.arrayWithObjects(null);
		trace("none", none.count().toInt());
		// past the registers
		var many = NSArray.arrayWithObjects(ns("1"), ns("2"), ns("3"), ns("4"), ns("5"), ns("6"), ns("7"), ns("8"), ns("9"), ns("10"), ns("11"), ns("12"));
		trace("many", many.count().toInt(), str(many.componentsJoinedByString(ns(" "))));
		var d = NSDictionary.dictionaryWithObjectsAndKeys(ns("one"), ns("k1"), ns("two"), ns("k2"));
		trace("dictionary", d.count().toInt(), str(cast d.objectForKey(ns("k2"))));
		trace("format", str(NSString.stringWithFormat(ns("%@ and %@, then %@"), ns("x"), ns("y"), three)));
		trace("format alone", str(NSString.stringWithFormat(ns("plain"))));
	});
}
