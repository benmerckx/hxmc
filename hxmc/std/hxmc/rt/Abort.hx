package hxmc.rt;

import hxmc.unsafe.*;

// How scoped code fails (docs/plans/lowlevel.md, "Scoped memory"): it cannot
// throw (no-GC code), so it ends the program with a message, exit status 70.
// Apart from DataStacks, so that a scoped view of GC memory (Slice, the maps'
// index: hxmc.rt.MapIndex) brings in no data stacks.
class Abort {
	@:hxmc.noGc @:hxmc.noReturn public static function outOfRange()
		die(Mem.cstr("hxmc: scoped memory: index out of range\n"));

	@:hxmc.noGc @:hxmc.noReturn public static function die(msg:Ptr) {
		#if (hxmc.target == "wasm32-wasi")
		var n = LibC.strlen(msg).toInt();
		hxmc.rt.wasm.Wasi.writeRaw(2, msg, n);
		hxmc.rt.wasm.Wasi.exit(70);
		#else
		var r = new Os.Report(Mem.stack(Os.Report.BYTES));
		r.cstr(msg, 0, -1);
		r.flush();
		Os.exit(70);
		#end
	}
}
