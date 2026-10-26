package hxmc.unsafe;

// Haxe functions called by C (docs/plans/lowlevel.md, "Callbacks"): a static
// function declared @:hxmc.callback, passed to C as its address:
//
//   @:hxmc.callback @:hxmc.unsafe static function onFree(p:Ptr):Void LibC.free(p);
//   ... Callback.addr(onFree) ...
//
// Parameters and the result: Int, Int64, Float, Ptr (C's int, int64_t,
// double, pointers). A @:hxmc.unsafe callback may run on any thread and in
// any state (a collector's finalizer, a BIO callback inside a blocking C
// call). Any other runs Haxe code that may collect: C may call it only on a
// thread of the runtime, from inside a C call that is not @:hxmc.fast (the
// compiler's wrapper leaves that call's safe region and enters it again on
// return). An exception thrown by a callback unwinds through the C frames
// to the Haxe handler, as the runtime's C natives always did: C libraries
// that keep state across a callback need the callback to catch instead.
extern class Callback {
	// the address of a @:hxmc.callback function: `f` names it (Class.field)
	static function addr(f:Dynamic):Ptr;
}
