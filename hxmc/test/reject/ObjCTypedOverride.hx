// A Haxe method Objective-C calls takes no span yet: Objective-C would
// pass C's address, which the method has no length of.
// expect: getBytes implements an Objective-C method that takes a span, an hxmc.Out or a C function pointer
import hxmc.Span;
import hxmc.unsafe.UInt8;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:hxmc.len(buffer, length) function getBytes(buffer:Span<UInt8>, length:Int):Void;
}

class Data extends NSObject {
	public function new() {}

	override function getBytes(buffer:Span<UInt8>, length:Int) {}
}

class ObjCTypedOverride {
	static function main()
		new Data();
}
