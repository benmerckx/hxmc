// WASI's path calls made by the program itself (as tsc-haxe's go.OsWasi
// makes them) in a WasmGC module: hxmc.rt.wasm.WasiApi imported from
// wasi_snapshot_preview1 (GcModule.libOf), given by the host over the linear
// memory (hxmc/bootstrap/wasmgc.mjs), paths resolved against its preopened
// directories (hxmc.rt.wasm.Wasi, read on the first one) and relative ones
// against the host's working directory. Natively the same through sys.
class WasiPaths {
	#if hxmc.wasm_gc
	// [errno] or [0, filetype, size]
	static function stat(path:String):Array<Int> {
		var p = @:privateAccess hxmc.rt.Str.toUtf8(path);
		var a = hxmc.rt.wasm.Wasi.absolute(p);
		hxmc.rt.wasm.Heap.free(p);
		var rel = hxmc.unsafe.Mem.stack(8), st = hxmc.unsafe.Mem.stack(64);
		var dir = hxmc.rt.wasm.Wasi.resolve(a, rel);
		var r = [44];
		if (dir >= 0) {
			var rp = hxmc.unsafe.Mem.getPtr(rel, 0);
			var e = hxmc.rt.wasm.WasiApi.path_filestat_get(dir, 1, hxmc.rt.wasm.Wasi.a32(rp), hxmc.rt.wasm.Heap.strlen(rp).toInt(), hxmc.rt.wasm.Wasi.a32(st));
			r = e != 0 ? [e] : [0, hxmc.unsafe.Mem.getU8(st, 16), hxmc.unsafe.Mem.getI32(st, 32)];
		}
		hxmc.rt.wasm.Heap.free(a);
		return r;
	}
	#else
	static function stat(path:String):Array<Int> {
		if (!sys.FileSystem.exists(path)) return [44];
		return sys.FileSystem.isDirectory(path) ? [0, 3, -1] : [0, 4, sys.FileSystem.stat(path).size];
	}
	#end

	static function show(path:String):String {
		var r = stat(path);
		return r[0] != 0 ? 'missing ($path)' : r[1] == 3 ? 'directory' : r[1] == 4 ? 'file of ${r[2]} bytes' : 'kind ${r[1]}';
	}

	static function main() {
		var file = "hxmc/test/wasmgc/WasiPaths.hx";
		Sys.println(show(file) == 'file of ${sys.io.File.getBytes(file).length} bytes');
		Sys.println(show(sys.FileSystem.absolutePath(file)) == show(file));
		Sys.println(show("hxmc/test/wasmgc"));
		Sys.println(show("hxmc/test/wasmgc/./../wasmgc"));
		Sys.println(show("/"));
		Sys.println(show("hxmc/test/wasmgc/no-such-file"));
	}
}
