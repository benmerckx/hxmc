// A protocol is Objective-C's: a Haxe class conforms to one only when it
// extends an Objective-C class (it has an Objective-C object then).
// expect: only a class extending an Objective-C class can
@:hxmc.objc extern interface NSCopying {
	function copyWithZone(zone:hxmc.unsafe.Ptr):NSCopying;
}

class Plain implements NSCopying {
	public function new() {}

	public function copyWithZone(zone:hxmc.unsafe.Ptr):NSCopying
		return this;
}

class ObjCProtocolNotPeer {
	static function main() {
		trace(new Plain() != null);
	}
}
