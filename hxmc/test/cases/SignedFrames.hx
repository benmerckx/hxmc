// Return addresses signed by pointer authentication (docs/hxmc.md, "Return
// addresses": arm64 on Linux, Android and Windows; elsewhere the frame is
// as any other): a function with a Mem.stack area that C writes signs its
// saved x30 (an area the optimizer keeps in registers is no memory). A
// call stack taken below it (hxmc.rt.Stacks.retOf drops the signature)
// names it and its callers, an exception thrown below it is caught above
// it, and it returns through its check, after the throw too.
import haxe.CallStack;
import haxe.io.Path;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;

class SignedFrames {
	static var sink = 0;

	static function item(s:StackItem):String
		return switch s {
			case FilePos(Method(c, m), f, l, _): c + "." + m + " " + Path.withoutDirectory(f) + ":" + l;
			case _: "?";
		}

	static function top(s:CallStack, n:Int):String
		return [for (i in 0...(n < s.length ? n : s.length)) item(s[i])].join(" < ");

	// (a body too large to inline)
	static function inner(n:Int):CallStack {
		if (n < 0) throw "below";
		for (i in 0...n)
			sink += i * 3 + (i % 5 == 0 ? 7 : 13) + (sink > 1000 ? -sink : sink >> 1);
		return CallStack.callStack();
	}

	// a signed frame: 64 bytes of frame area, filled by C before the call
	// and read back after it
	@:hxmc.unsafe(gc) static function signed(n:Int):String {
		var a = Mem.stack(64);
		LibC.memset(a, n, 64);
		var s = top(inner(n), 3);
		var sum = 0;
		for (i in 0...64)
			sum += Mem.getU8(a, i);
		return s + " / " + sum;
	}

	static function main() {
		trace(signed(3));
		try {
			signed(-1);
		} catch (e:String) {
			trace("caught " + e + ": " + top(CallStack.exceptionStack(), 3));
		}
		trace(signed(5));
	}
}
