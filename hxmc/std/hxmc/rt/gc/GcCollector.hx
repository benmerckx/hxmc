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

	// (hxmc.GcStats: the engine keeps no counters a module can read)
	public static function bytesAllocated():Float
		return 0;

	public static inline var RECORDS = 64;

	public static function threadBytesAllocated():Float
		return 0;

	public static function recordField(k:Int, field:Int):Float
		return 0;

	public static function recordCount():Int
		return 0;

	public static function clock():Float
		return haxe.Timer.stamp();

	public static function counts(which:Int):Int
		return 0;

	public static function pause(which:Int):Float
		return 0;

	public static function reached():Bool
		return false;

	public static function objsize(v:Dynamic, exclude:Array<Dynamic>, out:Array<Dynamic>):Float
		throw "Gc.objsize is not supported by -D hxmc.wasm-gc";
}
