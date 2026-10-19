package hxmc.rt.gc;

// -D hxmc.wasm-gc: hxmc.NativeGc over the engine's collector, which a module
// can neither run nor walk: a collection is the engine's to start (asking
// for one does nothing), finalisers never run (as on linear-memory
// WebAssembly), the heap's size is the host's (node's V8 heap in use), and
// object sizes are not known.
class GcCollector {
	public static function collect(full:Bool):Void {}

	public static function finalise(fn:Dynamic->Void, v:Dynamic):Void {}

	public static function runFinalisers():Void {}

	public static function heapBytes():Float
		return W.sysNum(13, null, null, 0);

	public static function reached():Bool
		return false;

	public static function objsize(v:Dynamic, exclude:Array<Dynamic>, out:Array<Dynamic>):Float
		throw "Gc.objsize is not supported by -D hxmc.wasm-gc";
}
