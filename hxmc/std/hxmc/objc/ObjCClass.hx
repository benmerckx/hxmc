package hxmc.objc;

// An Objective-C class object: what Objective-C's `Class` holds, an object
// itself (it answers the class's `+` methods). `ObjCClass.of(C)` is the class
// of C, an Objective-C class or a Haxe class extending one (registered
// first): for APIs that take classes (NSPasteboard's
// readObjectsForClasses:options:, NSWindow's restorationClass), which then
// send them class methods (a Haxe class's statics implementing them: docs/interop.md)
extern class ObjCClass implements Id {
	static function of<T:Id>(c:Class<T>):ObjCClass;
}
