// Scoped memory needs a linear memory: WasmGC has none (yet).
// expect: scoped memory needs a linear memory: not available with -D hxmc.wasm-gc
// target: wasm32-wasi
// define: hxmc.wasm-gc
@:hxmc.scoped class Code {
	public static function twice(n:Int):Int
		return n * 2;
}

class ScopedWasmGc {
	static function main()
		trace(Code.twice(1));
}
