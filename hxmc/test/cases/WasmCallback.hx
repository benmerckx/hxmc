import hxmc.unsafe.*;

// Haxe called by JavaScript after main returned (docs/interop.md,
// "WebAssembly"), as a browser's requestAnimationFrame calls a frame: main
// hands the host the addresses of @:hxmc.callback functions (their indices
// in the exported __indirect_function_table) and returns; the host
// (WasmCallback.cjs) calls them from node's event loop. Between the calls
// the runtime keeps what main left (statics, the heap): each call allocates
// enough for collections, throws and catches, and flushes what it printed.
// WebAssembly only.
@:hxmc.lib("host") extern class Host {
	@:hxmc.c("h_later") static function later(fn:Ptr, times:Int, arg:Float):Void;
}

class WasmCallback {
	static var kept:Array<String>;
	static var step:Int->String;

	static function main() {
		kept = [for (i in 0...100) "kept " + i];
		var base = 1000;
		step = n -> "step " + (base + n);
		Host.later(Callback.addr(onTick), 3, 0.5);
		trace("main returns");
	}

	@:hxmc.callback static function onTick(n:Int, x:Float):Int {
		var junk = [for (i in 0...20000) Std.string(i * n)];
		var caught = try {
			if (n % 2 == 1) throw "odd " + n;
			"even";
		} catch (e:String) e;
		kept.push(step(n));
		trace('tick $n $x: ${junk.length} $caught, ${kept.length} kept, ${kept[3]}, ${kept[kept.length - 1]}');
		Sys.stdout().flush();
		return n * 10;
	}
}
