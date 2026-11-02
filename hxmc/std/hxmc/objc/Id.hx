package hxmc.objc;

// Any Objective-C object: the root classes and protocols extend it, so every
// Objective-C class and protocol is one, and a Haxe class extending an
// Objective-C class. A type parameter bound to it (or to any Objective-C
// type) holds ids, as a lightweight generic's (`NSArray<ObjectType:Id = Id>`).
// It is no protocol of the runtime's: no class is said to conform to it, and
// `Std.isOfType(x, Id)` is true of every object (hxmc.ir.ObjC.isId)
@:hxmc.objc extern interface Id {}
