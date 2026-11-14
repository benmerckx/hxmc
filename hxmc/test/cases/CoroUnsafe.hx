// Coroutines marked @:hxmc.unsafe(gc) that use raw memory on both sides of
// a suspension. The coroutine transform moves a coroutine's body into a
// class of its own (its state machine), which keeps none of the function's
// metadata; RawCheck trusts that class with the function that makes it, and
// a coroutine closure's made in a trusted function the same. Built
// -D hxmc.strict: raw memory outside trusted code is an error there. Built
// without the module cache: the hoisted fields are in the order of their
// variables' ids, see CoroCatch.
// define: hxmc.strict
// define: hxmc.no-module-cache
import haxe.coro.*;
import haxe.coro.continuations.FunctionContinuation;
import haxe.coro.context.Context;
import hxmc.unsafe.*;

class CoroUnsafe {
	static var later:Array<Void->Void> = [];

	// suspends, then resumes with a value
	@:coroutine(transformed)
	static function valueLater(completion:IContinuation<Int>):SuspensionResult<Int> {
		later.push(() -> completion.resume(2, null));
		return cast SuspensionResult.suspended;
	}

	// a buffer written before the suspension, read after it
	@:hxmc.unsafe(gc) @:coroutine static function sum(n:Int):Int {
		var p = LibC.malloc(4 * n);
		for (i in 0...n)
			Mem.setI32(p, 4 * i, i);
		var k = valueLater();
		var s = 0;
		for (i in 0...n)
			s += Mem.getI32(p, 4 * i);
		LibC.free(p);
		return s * k;
	}

	// a coroutine closure in a trusted function
	@:hxmc.unsafe(gc) static function doubled(v:Int):Coroutine<() -> Int> {
		@:coroutine function f():Int {
			var b = IoBuffer.alloc(4);
			b.setInt32(0, v);
			var k = valueLater();
			var r = b.getInt32(0) * k;
			b.free();
			return r;
		}
		return f;
	}

	static function run<T>(name:String, c:Coroutine<() -> T>) {
		Sys.println("-- " + name);
		c(new FunctionContinuation(Context.empty, (r, e) -> Sys.println("result " + r + ", error " + (e == null ? "null" : e.message))));
		while (later.length > 0)
			later.shift()();
	}

	static function main() {
		run("a trusted coroutine", () -> sum(4));
		run("a coroutine closure in a trusted function", doubled(21));
	}
}
