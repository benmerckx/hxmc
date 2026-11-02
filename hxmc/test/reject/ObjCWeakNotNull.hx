// A weak field becomes nil once its object is gone: its type must say so.
// expect: a weak field becomes nil once its object is gone: declare it Null<...>
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

class Holder {
	@:hxmc.weak public var owner:NSObject;
	public function new() {}
}

class ObjCWeakNotNull {
	static function main()
		trace(new Holder().owner == null);
}
