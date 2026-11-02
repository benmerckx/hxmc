// A callback that may collect, called from a @:hxmc.fast C call, ends the
// program with a message (Threads.callbackBegin): the fast call's caller
// keeps references across it that a collection would not update. An
// @:hxmc.unsafe callback (it never collects) may be called so.
import hxmc.unsafe.*;

@:hxmc.c @:hxmc.fast extern class C {
	@:hxmc.indirect static function call2(f:Ptr, a:Int, b:Int):Int;
}

class FastCallbackDies {
	@:hxmc.callback @:hxmc.unsafe static function sum(a:Int, b:Int):Int
		return a + b;

	@:hxmc.callback static function allocating(a:Int, b:Int):Int {
		var s = [for (i in 0...10) "junk" + i];
		return a + b + s.length;
	}

	static function main() {
		Sys.println("unsafe: " + C.call2(Callback.addr(sum), 30, 12));
		Sys.stdout().flush();
		Sys.println("not reached: " + C.call2(Callback.addr(allocating), 1, 2));
	}
}
