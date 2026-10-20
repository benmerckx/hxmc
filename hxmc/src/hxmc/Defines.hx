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
			key: "hxmc.null_checks",
			doc: "Whether hxmc tests references against null before it dereferences them (null throws \"Null Access\"): 1 or 0. Not defined: on WebAssembly, where a null access would read memory or trap; off on the native targets, where the access faults and the runtime's fault handler throws.",
			flags: [core.DefineRegistry.DefineParameter.HasParam("0 | 1")]
		});
		core.DefineRegistry.all.push({
			key: "hxmc.gc_prefault",
			doc: "Linux: once the heap's old space passes 64 MB, a helper thread of the garbage collector faults in its pages ahead of the minor collections, which otherwise wait for the kernel to zero each fresh page: less wall time for more CPU time (RT_PREFAULT=0 turns it off at run time). Not defined: no helper.",
			flags: []
		});
		core.DefineRegistry.all.push({
			key: "hxmc.interp",
			doc: "The program's functions (or those of the modules named, by prefix) are run by an interpreter of hxmc's Mir inside the program, with the same memory, layouts and runtime as compiled code (an experiment). Not on WebAssembly.",
			flags: [core.DefineRegistry.DefineParameter.HasParam("module prefixes")]
		});
	}
}
