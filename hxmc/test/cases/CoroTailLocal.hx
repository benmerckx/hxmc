// A local declared in one state of a coroutine and read in a later state
// only by an expression that the transform builds afterwards: the arguments
// of a tail call (`return c ? f(x) : g(x)`, the reported form, and an
// if/else of returns), a returned value, and the arguments of a call that
// never suspends. The walk that finds the locals used across states saw
// only the placeholders of those expressions, so the local was not hoisted
// and the later state read it undeclared: "Unbound variable: x<N>" on hxmc,
// "Unbound variable" on Eval, and on JS the value undefined once a suspension
// lies between (upstream's coroToTexpr.ml).
// Built without the module cache: the hoisted fields are named after
// variable ids (`_hx_hoisted<id>`, as upstream), see CoroCatch.
// define: hxmc.no-module-cache
import haxe.coro.*;
import haxe.coro.continuations.FunctionContinuation;
import haxe.coro.context.Context;

class CoroTailLocal {
	static var later:Array<Void->Void> = [];

	static function out(s:String) {
		#if js
		js.Syntax.code("console.log({0})", s);
		#else
		Sys.println(s);
		#end
	}

	// suspends, then resumes with a value
	@:coroutine(transformed)
	static function valueLater(completion:IContinuation<Int>):SuspensionResult<Int> {
		later.push(() -> completion.resume(2, null));
		return cast SuspensionResult.suspended;
	}

	// returns without suspending, declared so
	@:coroutine(transformed, outcome = {noSuspend: true})
	static function lengthNow(completion:IContinuation<Any>, s:String):SuspensionResult<Int>
		return SuspensionResult.withResult(s.length);

	@:coroutine static function a(n:Int, s:String):String {
		valueLater();
		return "a " + n + " " + s;
	}

	@:coroutine static function b(n:Int, s:String):String {
		valueLater();
		return "b " + n + " " + s;
	}

	// the reported form: a ternary of tail calls in a branch
	@:coroutine static function ternary(flag:Bool):String {
		var mobile = flag ? "android" : null;
		if (mobile != null)
			return flag ? a(1, mobile) : b(1, mobile);
		return "none";
	}

	// the same with the local read by the second call only
	@:coroutine static function ternaryElse(flag:Bool):String {
		var name = flag ? null : "ios";
		if (name != null || flag)
			return flag ? a(2, "-") : b(2, name);
		return "none";
	}

	// an if/else of returns in tail position, after a suspending call:
	// a tail call and a returned local
	@:coroutine static function ifElse(flag:Bool):String {
		var label = "label " + flag;
		valueLater();
		if (flag)
			return a(3, label);
		else
			return label;
	}

	// a call that never suspends, after a suspending call
	@:coroutine static function syncCall(s:String):Int {
		var t = s + "!";
		valueLater();
		var n = lengthNow(t);
		return n;
	}

	static function run<T>(name:String, c:Coroutine<() -> T>) {
		out("-- " + name);
		c(new FunctionContinuation(Context.empty, (r, e) -> out("result " + r + ", error " + (e == null ? "null" : e.message))));
		while (later.length > 0)
			later.shift()();
	}

	static function main() {
		run("ternary of tail calls, true", () -> ternary(true));
		run("ternary of tail calls, false", () -> ternary(false));
		run("the local in the else call", () -> ternaryElse(false));
		run("the local unused", () -> ternaryElse(true));
		run("if/else of returns, tail call", () -> ifElse(true));
		run("if/else of returns, the local", () -> ifElse(false));
		run("a call that never suspends", () -> syncCall("abc"));
	}
}
