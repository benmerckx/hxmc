package hxmc.com;

// An [out] interface pointer (IFoo **) of a COM method or a C function: the
// call passes the address of a slot, and stores what C put there into value
// (its reference taken over, null for NULL), as an [out, retval] result is
// (docs/interop.md, "COM").
//
//   var factory = new Out<IDWriteFactory>();
//   DWrite.DWriteCreateFactory(0, Com.iidOf(IDWriteFactory), factory);
//   factory.value.CreateTextFormat(...);
class Out<T> {
	public var value:Null<T>;

	public function new() {}
}
