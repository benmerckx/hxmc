// Only a field holding an Objective-C object can be unowned.
// expect: only a field holding an Objective-C object can be unowned
class Holder {
	@:hxmc.unowned public var name:Null<String>;
	public function new() {}
}

class ObjCUnownedNotObjC {
	static function main()
		trace(new Holder().name);
}
