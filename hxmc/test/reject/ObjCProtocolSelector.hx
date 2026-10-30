// A method implementing a protocol's has the protocol's selector: one of its
// own that differs is an error, not a second method Objective-C never calls.
// expect: implements the Objective-C method parser:foundCharacters:, but its @:selector says
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

@:hxmc.objc extern interface NSXMLParserDelegate {
	@:selector("parser:foundCharacters:") @:optional function foundCharacters(parser:NSObject, s:NSObject):Void;
}

class Delegate extends NSObject implements NSXMLParserDelegate {
	public function new() {}

	@:selector("parser:foundString:") public function foundCharacters(parser:NSObject, s:NSObject) {}
}

class ObjCProtocolSelector {
	static function main() {
		trace(new Delegate() != null);
	}
}
