// A callback that may collect, called from a @:hxmc.fast C call, ends the
// program with a message (Threads.callbackBegin): the fast call's caller
// keeps references across it that a collection would not update. An
// @:hxmc.unsafe callback (it never collects) may be called so.
import hxmc.unsafe.*;

@:hxmc.c @:hxmc.fast extern class C {
	static function qsort(base:Ptr, n:Int64, size:Int64, cmp:Ptr):Void;
}

class FastCallbackDies {
	@:hxmc.callback @:hxmc.unsafe static function byValue(x:Ptr, y:Ptr):Int
		return Mem.getI32(x, 0) - Mem.getI32(y, 0);

	@:hxmc.callback static function allocating(x:Ptr, y:Ptr):Int {
		var s = [for (i in 0...10) "junk" + i];
		return Mem.getI32(x, 0) - Mem.getI32(y, 0) + s.length - 10;
	}

	static function main() {
		var buf = LibC.malloc(4 * 8);
		for (i in 0...8)
			Mem.setI32(buf, 4 * i, (i * 5) % 8);
		C.qsort(buf, 8, 4, Callback.addr(byValue));
		Sys.println("unsafe: " + [for (i in 0...8) Mem.getI32(buf, 4 * i)].join(","));
		Sys.stdout().flush();
		C.qsort(buf, 8, 4, Callback.addr(allocating));
		Sys.println("not reached");
	}
}
