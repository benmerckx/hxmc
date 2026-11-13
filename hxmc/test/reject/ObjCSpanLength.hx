// A message's span passes its address alone: its count is a parameter of
// its own, part of the selector, which @:hxmc.len names.
// expect: Objective-C method dataWithBytes: the span bytes needs @:hxmc.len(bytes, n): a message passes its address alone
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSData {
	static function dataWithBytes(bytes:ReadOnlySpan<UInt8>, length:Int):NSData;
}

class ObjCSpanLength {
	static function main() {
		var x:UInt8 = 1;
		NSData.dataWithBytes(ReadOnlySpan.of(x), 1);
	}
}
