// Coroutines after the pin's move to 74c5b464e: hoisted fields and restored
// locals named after their variables (d36dba484, 397035e5a: shadowed and
// generated variables, names of inherited fields, an abstract's `this`),
// haxe.Exception-like catches (c396ab65c), the error field cleared after a
// resumption's error is taken (af809ea00) and locals read only by deferred
// expressions (491505c90). build.hxml runs it as it is, stack-traces.hxml
// with -D coro.stack-traces and -debug (d358d00c6).
import haxe.coro.*;
import haxe.coro.continuations.FunctionContinuation;
import haxe.coro.context.Context;

abstract Counter(Int) from Int {
	@:coroutine public function addLater(n:Int):Int {
		var before = this;
		var got = Coro.valueLater(n);
		return before + this + got;
	}
}

class Coro {
	static var later:Array<Void->Void> = [];

	static function out(s:String)
		Sys.println(s);

	static var pending:Dynamic;

	// suspends, then resumes with `pending`
	@:coroutine(transformed)
	static function resumeLater(completion:IContinuation<Int>):SuspensionResult<Int> {
		var v:Int = pending;
		later.push(() -> completion.resume(v, null));
		return cast SuspensionResult.suspended;
	}

	// suspends, then resumes with `pending` as an error
	@:coroutine(transformed)
	static function throwLater(completion:IContinuation<Int>):SuspensionResult<Int> {
		var v:Dynamic = pending;
		var e = Std.isOfType(v, haxe.Exception) ? (v : haxe.Exception) : new haxe.ValueException(v);
		later.push(() -> completion.resume(null, e));
		return cast SuspensionResult.suspended;
	}

	// returns `pending` without suspending
	@:coroutine(transformed)
	static function returnNow(completion:IContinuation<Any>):SuspensionResult<Int>
		return SuspensionResult.withResult(pending);

	@:coroutine public static function valueLater(v:Int):Int {
		pending = v;
		return resumeLater();
	}

	@:coroutine static function failsLater(v:Dynamic):Int {
		pending = v;
		return throwLater();
	}

	@:coroutine static function now(v:Int):Int {
		pending = v;
		return returnNow();
	}

	@:coroutine static function shadowed():String {
		var x = valueLater(1);
		var r = "";
		{
			var x = valueLater(2);
			r += x;
			{
				var x = valueLater(3);
				r += x;
			}
			r += x;
		}
		return r + x;
	}

	@:coroutine static function generated():String {
		var sum = 0;
		for (i in [10, 20, 30])
			sum += valueLater(i);
		for (i in 0...3)
			sum += valueLater(i);
		var a = [for (i in 0...2) i];
		return sum + " " + a;
	}

	@:coroutine static function inheritedNames():String {
		var completion = valueLater(1);
		var state = valueLater(2);
		var result = valueLater(3);
		var error = valueLater(4);
		var context = valueLater(5);
		var _hx_captured = valueLater(6);
		var _g = valueLater(7);
		var _g1 = valueLater(8);
		return [completion, state, result, error, context, _hx_captured, _g, _g1].join(",");
	}

	@:coroutine static function arguments(a:Int, b:String, ?c:Int):String {
		var d = valueLater(a);
		var a = d + 1;
		return a + b + c;
	}

	@:coroutine static function catches():String {
		var r = [];
		try failsLater("str") catch (e:haxe.Exception) r.push("exception " + e.message);
		try failsLater("str") catch (e:String) r.push("string " + e);
		try failsLater(42) catch (e:haxe.Exception) r.push("exception " + e.message + " " + Std.isOfType(e, haxe.Exception));
		try failsLater(new haxe.Exception("ex")) catch (e:Dynamic) r.push("dynamic " + Std.isOfType(e, haxe.Exception));
		try failsLater(1.5) catch (e:String) r.push("no") catch (e:haxe.Exception) r.push("second " + e.message);
		try {
			try failsLater("inner") catch (e:Int) r.push("no");
		} catch (e:haxe.Exception) r.push("outer " + e.message);
		return r.join("; ");
	}

	// (a ValueException is unwrapped before it is tested: not caught as one, upstream as here)
	@:coroutine static function valueExceptionCatch():String {
		try failsLater(new haxe.ValueException("ve")) catch (e:haxe.ValueException) return "value " + e.value;
		return "not caught";
	}

	@:coroutine static function caughtThenCalls():String {
		try failsLater("x") catch (e:haxe.Exception) out("caught " + e.message);
		var n = now(1);
		try failsLater("y") catch (e:Dynamic) out("caught again");
		var m = now(2);
		var k = valueLater(3);
		return "after " + n + m + k;
	}

	@:coroutine static function deferredReads(c:Bool):Int {
		var a = now(5);
		var b = valueLater(1);
		if (c)
			return a;
		return c ? now(a) : valueLater(a + b);
	}

	static function run<T>(name:String, c:Coroutine<() -> T>) {
		out("-- " + name);
		c(new FunctionContinuation(Context.empty, (r, e) -> out("result " + r + ", error " + (e == null ? "null" : e.message))));
		while (later.length > 0)
			later.shift()();
	}

	static function main() {
		run("shadowed", shadowed);
		run("generated", generated);
		run("inherited names", inheritedNames);
		run("arguments", () -> arguments(1, "b"));
		run("catches", catches);
		run("value exception", valueExceptionCatch);
		run("caught, then calls", caughtThenCalls);
		run("deferred reads, true", () -> deferredReads(true));
		run("deferred reads, false", () -> deferredReads(false));
		var counter:Counter = 5;
		run("abstract this", () -> counter.addLater(2));
	}
}
