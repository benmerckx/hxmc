// A field is weak or unowned, not both.
// expect: a field is weak or unowned, not both
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

class Holder {
	@:hxmc.weak @:hxmc.unowned public var o:Null<NSObject>;
	public function new() {}
}

class ObjCUnownedWeak {
	static function main()
		trace(new Holder().o == null);
}
