import hxmc.objc.AutoreleasePool;
import hxmc.objc.ObjCClass;
import hxmc.objc.Selector;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// class methods of Objective-C mode classes (docs/interop.md, "Objective-C
// classes in Haxe"): as a peer class's (ObjCClassMethods), statics
// implementing the `+` methods of a superclass or of an adopted protocol are
// the metaclass's; a subclass's static overrides; others are Haxe's only
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements hxmc.objc.Id {
	function respondsToSelector(sel:Selector):Bool;
	@:hxmc.framework("Foundation") static function description():NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	static function arrayWithObject(o:hxmc.objc.Id):NSArray;
	@:selector("description") function text():NSString;
}

// a protocol with class methods (made at run time: no image declares it)
@:hxmc.objc("HxmcShapes") extern interface Shapes {
	static function sides():Int;
	@:selector("scaled:by:") static function scaled(x:Float, by:Float):Float;
	static function named(prefix:NSString):NSString;
}

@:hxmc.objc class Triangle extends NSObject implements Shapes {
	public extern static function alloc():Triangle;

	public static var asked = 0;

	public static function sides():Int {
		asked++;
		return 3;
	}

	public static function scaled(x:Float, by:Float):Float
		return x * by;

	public static function named(prefix:NSString):NSString
		return cast Strings.toNSString(Strings.ofNSString(cast prefix) + "triangle");

	// NSObject's class method, overridden
	public static function description():NSString
		return cast Strings.toNSString("Triangle!");

	// Haxe's only: no class method of a superclass's or a protocol's
	public static function helper():Int
		return 1;
}

@:hxmc.objc class Square extends Triangle {
	public extern static function alloc():Square;

	public static function sides():Int
		return 4;
}

@:hxmc.objc class Pentagon extends Triangle {
	public extern static function alloc():Pentagon;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Runtime {
	@:hxmc.fast @:hxmc.lib("/usr/lib/libSystem.B.dylib") static function dlsym(handle:Ptr, name:CString):Ptr;
	static function objc_getClass(name:CString):ObjCClass;
	static function class_getName(cls:ObjCClass):CString;
	@:hxmc.indirect static function sendInt(f:Ptr, cls:ObjCClass, sel:Selector):Int;
	@:hxmc.indirect static function sendScaled(f:Ptr, cls:ObjCClass, sel:Selector, x:Float, by:Float):Float;
	@:hxmc.indirect static function sendNamed(f:Ptr, cls:ObjCClass, sel:Selector, prefix:NSString):NSString;
}

class ObjCModeClassMethods {
	static function main() AutoreleasePool.run(() -> {
		var msgSend = Runtime.dlsym(Ptr.ofI64(-2), cast Mem.cstr("objc_msgSend"));
		var triangle = ObjCClass.of(Triangle), square = ObjCClass.of(Square), pentagon = ObjCClass.of(Pentagon);
		trace("names", Runtime.class_getName(triangle).toString(), Runtime.class_getName(square).toString(),
			ObjCClass.of(NSString) == Runtime.objc_getClass(cast Mem.cstr("NSString")));
		// (a class object answers its class methods: respondsToSelector:, an
		// instance method of the root class, of the class object)
		function responds(c:ObjCClass, s:Selector)
			return (cast c : NSObject).respondsToSelector(s);
		trace("responds", responds(triangle, Selector.of("sides")), responds(triangle, Selector.of("scaled:by:")), responds(pentagon, Selector.of("named:")), responds(triangle, Selector.of("helper")),
			responds(ObjCClass.of(NSString), Selector.of("sides")));
		trace("sent", Runtime.sendInt(msgSend, triangle, Selector.of("sides")), Runtime.sendInt(msgSend, square, Selector.of("sides")),
			Runtime.sendInt(msgSend, pentagon, Selector.of("sides")), Triangle.asked);
		trace("arguments", Runtime.sendScaled(msgSend, triangle, Selector.of("scaled:by:"), 2, 1.5),
			Strings.ofNSString(cast Runtime.sendNamed(msgSend, square, Selector.of("named:"), cast Strings.toNSString("a "))));
		// Foundation sending the class +description (formatting an array of it)
		var text = Strings.ofNSString(cast NSArray.arrayWithObject(triangle).text());
		trace("description", text.indexOf("Triangle!") >= 0, Triangle.helper());
		hxmc.rt.Gc.collect(true);
		trace("after a collection", Runtime.sendInt(msgSend, square, Selector.of("sides")));
	});
}
