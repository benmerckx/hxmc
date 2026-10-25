import hxmc.scoped.*;
import hxmc.unsafe.UInt8;

// The scoped C boundary on wasm32 (docs/plans/lowlevel.md, "The scoped C
// boundary"): a view parameter is its address and its length, both i32 as
// wasm32's C and WASI take them; the host here is WasmViews.cjs.
// WebAssembly only (ScopedCBoundary: natively).
@:hxmc.lib("host") extern class Views {
	@:hxmc.c("h_sum") static function sum(b:Slice<UInt8>):Int;
	@:hxmc.c("h_utf8") static function utf8Length(s:Str):Int;
	@:hxmc.c("h_fill") static function fill(b:Slice<UInt8>, v:Int):Void;
}

@:hxmc.scoped class Calls {
	public static function run():Int {
		var b:Slice<UInt8> = [1, 2, 3, 250];
		var s = Views.sum(b) * 1000 + Views.sum(b.sub(1, 2));
		var f = new Fixed<UInt8, 8>();
		Views.fill(f.view().sub(2, 3), 7);
		return s + Views.sum(f.view()) * 100000;
	}

	public static function text():Int
		return Views.utf8Length('héllo wörld');
}

class WasmViews {
	static function main() {
		Sys.println(Calls.run());
		Sys.println(Calls.text());
	}
}
