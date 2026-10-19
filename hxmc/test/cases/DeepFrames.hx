import hxmc.unsafe.*;

// Recursion whose frames hold more than 1 MB of frame areas at once. On
// WebAssembly frame areas (Mem.stack, a try function's locals kept in
// memory) live in linear memory below the stack-pointer global: the linker's
// 1 MB stack right above the data, past which frames silently overwrote the
// statics, the runtime's tables and the method tables (the compiler typing
// ~440 generated modules: a missing environment, "Cannot call a non-function",
// "null function or function signature mismatch"). The runtime now gives the
// program a stack as large as the shadow stack (RT_STACK_MB, 4 MB by default)
// and each frame checks its end.
class DeepFrames {
	static var names:Array<String>;
	static var calls:Map<String, Int->Int>;

	// 4 KB of frame area per level, written before the call below and read after it
	@:hxmc.noGc static function down(n:Int):Int {
		var buf = Mem.stack(4096);
		for (i in 0...1024)
			Mem.setI32(buf, 4 * i, n * 31 + i);
		var r = n == 0 ? 0 : down(n - 1);
		var ok = 0;
		for (i in 0...1024)
			if (Mem.getI32(buf, 4 * i) == n * 31 + i) ok++;
		return r + ok;
	}

	// the same through try functions (their locals live in the frame)
	static function tries(n:Int, acc:Int):Int {
		var a = n % 7, b = acc % 1000 + 1;
		try {
			if (n == 0) throw "bottom";
			b += tries(n - 1, acc + a);
		} catch (e:String) {
			b += e.length;
		}
		return a + b;
	}

	static function main() {
		names = [for (i in 0...8) "name" + i];
		calls = ["double" => x -> x * 2, "square" => x -> x * x];
		for (depth in [100, 400, 700])
			Sys.println("down " + depth + ": " + down(depth));
		Sys.println("tries: " + tries(2000, 0));
		// what lives in the data and the heap survived the frames
		Sys.println(names.join(","));
		Sys.println(calls["double"](21) + " " + calls["square"](12));
		var s = new StringBuf();
		for (i in 0...1000)
			s.add(i % 10);
		Sys.println(s.toString().length + " " + Std.string([1, 2, 3].map(x -> x + 1)));
	}
}
