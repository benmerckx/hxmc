package hxmc.objc;

// An Objective-C block of a function type F where no message's signature
// says so (a C function's parameter, a field, a value): an id, held as ids
// are (docs/interop.md, "Objective-C"). A function F becomes one (a heap
// block calling it, which keeps it alive while the block lives), and it
// becomes a function F (one calling the block, which holds a reference to
// it; a block made of a function is that function again): hxmc.ir.ObjC
abstract Block<F>(hxmc.unsafe.Ptr) {
	@:from public static extern function ofFunction<F>(f:F):Block<F>;
	@:to public extern function toFunction():F;
}
