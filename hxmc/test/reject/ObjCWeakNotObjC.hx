// Only a field holding an Objective-C object can be weak.
// expect: only a field holding an Objective-C object can be weak
class Holder {
	@:hxmc.weak public var name:Null<String>;
	public function new() {}
}

class ObjCWeakNotObjC {
	static function main()
		trace(new Holder().name);
}
