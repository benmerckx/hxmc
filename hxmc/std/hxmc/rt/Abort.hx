package hxmc.rt;

import hxmc.unsafe.*;

// How scoped code fails (docs/plans/lowlevel.md, "Scoped memory"): it cannot
// throw (no-GC code), so it ends the program with a message, exit status 70.
// Apart from DataStacks, so that a scoped view of GC memory (Slice, the maps'
// index: hxmc.rt.MapIndex) brings in no data stacks.
class Abort {
	#if hxmc.wasm_gc
	@:hxmc.noGc @:hxmc.noReturn public static function outOfRange()
		die("hxmc: scoped memory: index out of range\n");

	@:hxmc.noGc @:hxmc.noReturn public static function die(msg:String) {
		hxmc.rt.gc.W.write(2, msg);
		hxmc.rt.gc.GcSys.exit(70);
		hxmc.rt.gc.W.trap();
	}
	#else
	@:hxmc.noGc @:hxmc.noReturn public static function outOfRange()
		dieC(Mem.cstr("hxmc: scoped memory: index out of range\n"));

	// msg: a string literal
	public static inline function die(msg:String)
		dieC(Mem.cstr(msg));

	@:hxmc.noGc @:hxmc.noReturn public static function dieC(msg:Ptr) {
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
	#end
}
