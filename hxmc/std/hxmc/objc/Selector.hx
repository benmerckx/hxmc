package hxmc.objc;

// An Objective-C selector (SEL): `Selector.of("moveDown:")` is the
// selector of a literal name, read from the program's selector references
// as a message's is (hxmc.ir.ObjC)
abstract Selector(hxmc.unsafe.Ptr) {
	public static extern function of(name:String):Selector;
}
