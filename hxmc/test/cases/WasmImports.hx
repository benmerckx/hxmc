import hxmc.unsafe.*;

// C functions on WebAssembly (docs/plans/lowlevel.md): imports of the module
// @:hxmc.lib names ("env" by default), in wasm32's C convention (pointers
// as i32, Float32 as f32, Int64 as i64); the host here is WasmImports.cjs
// (HXMC_WASM_IMPORTS, hxmc/bootstrap/wasi.mjs). WebAssembly only.
@:hxmc.lib("host") extern class Host {
	@:hxmc.c("h_mix") static function mix(a:Int, b:Float32, c:Float, d:Int64, e:UInt8):Float32;
	@:hxmc.c("h_strlen") static function strlen(s:CString):Int;
	@:hxmc.c("h_buffer") static function buffer():Ptr<Int32>;
}

extern class Env {
	@:hxmc.c("e_twice") static function twice(v:Int):Int;
}

class WasmImports {
	static function main() {
		trace(Host.mix(1, 2.5, 0.25, 7, 300));
		Arena.scoped(a -> trace(Host.strlen(a.cstring("héllo"))));
		var p = Host.buffer();
		trace(p[0], p[1], p[2]);
		trace(Env.twice(21));
		trace(hxmc.test.WasmLib.h_lib(5));
		Arena.scoped(a -> trace(Libc.strlen(a.cstring("wasm"))));
		var e = Libc.errno();
		e[0] = 34;
		trace(Libc.errno()[0]);
	}
}

// C functions the runtime implements in Haxe (hxmc.rt.wasm.Libc, Heap): calls
// of those functions in their own convention, not imports (@:hxmc.fast, as
// the runtime declares them)
@:hxmc.fast extern class Libc {
	@:hxmc.c("__errno_location") static function errno():Ptr<Int32>;
	@:hxmc.c("strlen") static function strlen(s:CString):Int64;
}
