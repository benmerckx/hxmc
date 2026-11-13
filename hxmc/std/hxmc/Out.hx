package hxmc;

// An out-parameter of an object or a handle (T **): the call passes the
// address of a slot, which starts NULL, and stores what C put there into
// value after it (null for NULL) (docs/interop.md, "Typed bindings"). T is a
// COM interface (its reference taken over), an Objective-C or Core
// Foundation object (borrowed as ARC's __autoreleasing out-parameters are;
// owned by a C function of the Create rule or one naming it in
// @:hxmc.retained(p)), or a @:hxmc.handle.
//
//   var error = new Out<NSError>();
//   if (!data.writeToFile("/tmp/x", 0, error)) trace(error.value.localizedDescription);
class Out<T> {
	public var value:Null<T>;

	public function new() {}
}
