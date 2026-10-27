package hxmc.rt.wasm;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The program's end and uncaught exceptions on WebAssembly (docs/hxmc.md,
// "WebAssembly"; the field names are hxmc.rt.Names on every target).
@:hxmc.wasm @:keep
class Exit {
	// ---- the program's end

	@:hxmc.export("rt_main_done") @:hxmc.unsafe static function mainDone():Void {
		Wasi.flush();
		Gc.report(); // (RT_STATS)
	}

	// rt_throw without a handler (wasm.LinkWasm's rt_throw calls it)
	@:hxmc.export("hx_uncaught") static function uncaught(v:Dynamic):Void {
		var s:String = hxmc.rt.Dyn.stdString(v);
		Wasi.flush();
		Wasi.writeStr(2, "Uncaught exception: ");
		Wasi.writeStr(2, s);
		Wasi.writeStr(2, "\n");
		WasiApi.proc_exit(1);
	}
}
