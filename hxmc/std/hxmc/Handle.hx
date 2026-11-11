package hxmc;

// What safe code asks of a handle (docs/interop.md, "Handles"): a
// @:hxmc.handle abstract, which only a C function's result or @:hxmc.unsafe
// code makes.
extern class Handle {
	// whether h is not its type's invalid value (@:hxmc.handle(v); a
	// handle without one: always true)
	static function valid<T>(h:T):Bool;
}
