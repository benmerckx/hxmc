// An hxmc.Out<T> holds what C stores: an object of an extern class, not of
// a Haxe class extending one (C stores its id, not its Haxe object).
// expect: hxmc.Out<View>: a Haxe class's objects are not stored by C (an Out of its Objective-C superclass)
import hxmc.Out;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function take(o:Out<View>):Void;
}

class View extends NSObject {}

class ObjCOutHaxeClass {
	static function main()
		NSObject.alloc().init().take(new Out<View>());
}
