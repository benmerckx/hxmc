package hxmc;

// Target-specific help entries, installed only by the hxmc entry points.
// Keep the reference compiler's registry in haxe/src unchanged.
class Defines {
	static var installed = false;

	public static function install():Void {
		if (installed) return;
		installed = true;
		core.DefineRegistry.all.push({
			key: "hxmc.native_array_outofbounds",
			doc: "What an access of an hxmc.NativeArray or haxe.ds.Vector out of bounds does on hxmc: throws (haxe.exceptions.ArgumentException), or silent (a read gives the default value, a write does nothing). Not defined: not tested (unspecified).",
			flags: [core.DefineRegistry.DefineParameter.HasParam("throws | silent")]
		});
		core.DefineRegistry.all.push({
			key: "hxmc.gc_prefault",
			doc: "Linux: once the heap's old space passes 64 MB, a helper thread of the garbage collector faults in its pages ahead of the minor collections, which otherwise wait for the kernel to zero each fresh page: less wall time for more CPU time (RT_PREFAULT=0 turns it off at run time). Not defined: no helper.",
			flags: []
		});
	}
}
