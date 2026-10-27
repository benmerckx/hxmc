// A coroutine that catches an error which resumed it asynchronously, then
// calls a coroutine that returns without suspending: the state after that
// call read the continuation's error slot, which still held the caught
// error, and threw it again (upstream's coroToTexpr.ml, the same on Eval
// and JS). Also with a catch-all (Haxe has no `finally`; a catch-all is
// its closest form), with cleanup that rethrows to an outer catch, with a
// suspending call after the catch, with the catch inside a callee, and with
// an error that a callee returns synchronously (no resumption, the control).
// Built without the module cache: the hoisted fields are named after
// variable ids (`_hx_hoisted<id>`, as upstream), which continue from the
// cache's store, so Crosshost's native tool would name them otherwise than
// the WebAssembly one (which has no cache).
// define: hxmc.no-module-cache
import haxe.coro.*;
import haxe.coro.continuations.FunctionContinuation;
import haxe.coro.context.Context;

class CoroCatch {
	static var later:Array<Void->Void> = [];

	static function out(s:String) {
		#if js
		js.Syntax.code("console.log({0})", s);
		#else
		Sys.println(s);
		#end
	}

	// suspends, then resumes with an error
	@:coroutine(transformed)
	static function failsLater(completion:IContinuation<Int>):SuspensionResult<Int> {
		later.push(() -> completion.resume(null, new haxe.Exception("x")));
		return cast SuspensionResult.suspended;
	}

	// suspends, then resumes with a value
	@:coroutine(transformed)
	static function valueLater(completion:IContinuation<Int>):SuspensionResult<Int> {
		later.push(() -> completion.resume(2, null));
		return cast SuspensionResult.suspended;
	}

	// returns without suspending
	@:coroutine(transformed)
	static function now(completion:IContinuation<Any>):SuspensionResult<Int>
		return SuspensionResult.withResult(1);

	// throws without suspending
	@:coroutine(transformed)
	static function failsNow(completion:IContinuation<Any>):SuspensionResult<Int>
		return SuspensionResult.withError(new haxe.Exception("y"));

	@:coroutine static function catchThenCall():String {
		try failsLater() catch (e:haxe.Exception) out("caught " + e.message);
		var n = now();
		return "after: " + n;
	}

	@:coroutine static function catchAllThenCall():String {
		var cleaned = false;
		try failsLater() catch (e:Dynamic) cleaned = true;
		var n = now();
		return "cleaned " + cleaned + ", after: " + n;
	}

	@:coroutine static function cleanupRethrowThenCall():String {
		try {
			try failsLater() catch (e:haxe.Exception) {
				out("cleanup");
				throw e;
			}
		} catch (e:haxe.Exception) out("outer caught " + e.message);
		var n = now();
		return "after: " + n;
	}

	@:coroutine static function catchThenSuspend():String {
		try failsLater() catch (e:haxe.Exception) out("caught " + e.message);
		var n = valueLater();
		var m = now();
		return "after: " + n + " " + m;
	}

	@:coroutine static function inner():Int {
		try failsLater() catch (e:haxe.Exception) out("inner caught " + e.message);
		return now() + 10;
	}

	@:coroutine static function nested():String {
		var n = inner();
		var m = now();
		return "after: " + n + " " + m;
	}

	@:coroutine static function syncCatchThenCall():String {
		try failsNow() catch (e:haxe.Exception) out("caught " + e.message);
		var n = now();
		return "after: " + n;
	}

	static function run(name:String, c:Coroutine<() -> String>) {
		out("-- " + name);
		c(new FunctionContinuation(Context.empty, (r, e) -> out("result " + r + ", error " + (e == null ? "null" : e.message))));
		while (later.length > 0)
			later.shift()();
	}

	static function main() {
		run("catch, then a call that does not suspend", catchThenCall);
		run("catch-all, then a call that does not suspend", catchAllThenCall);
		run("cleanup rethrown to an outer catch, then a call", cleanupRethrowThenCall);
		run("catch, then a suspending call", catchThenSuspend);
		run("the catch in a callee", nested);
		run("a synchronous error caught, then a call", syncCatchThenCall);
	}
}
