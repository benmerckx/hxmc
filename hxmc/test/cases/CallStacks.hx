// Call stacks (upstream's unit.TestExceptions.testExceptionStack and
// teststd TestCallStack): haxe.CallStack.callStack(), an exception's stack
// where it is made (new, a subclass's constructor, Exception.thrown) or
// thrown and caught, a value caught (the stack of its throw), and
// haxe.CallStack.exceptionStack() after a throw, from the frame records
// through the program's table of functions and lines (hxmc.rt.Stacks,
// hxmc/src/hxmc/StackTable.hx); a local function, a method called through a
// closure, a frame in a constructor, recursion. Each line prints the first
// frames as method, file and line; the functions have a try each or bodies
// too large, which keeps them from being inlined (an inlined frame is its
// caller's). The output is the reference's (--interp) but for the two
// exception stacks after `throw "deep"` (the traces of lines 95 and 96), where Eval names
// the catching function alone and hxmc, as hl and cpp, the frames from the
// throw up to it (throw2 three times, throw1, main).
import haxe.CallStack;
import haxe.Exception;
import haxe.io.Path;

class MyError extends Exception {
	public function new(m:String) {
		super(m);
	}
}

class NoCtorError extends MyError {}

class Holder {
	public var stack:CallStack;

	public function new() {
		try {
			stack = CallStack.callStack();
		} catch (e:Dynamic) {}
	}
}

class CallStacks {
	static function item(s:StackItem):String {
		return switch s {
			case FilePos(Method(c, m), f, l, _): c + "." + m + " " + Path.withoutDirectory(f) + ":" + l;
			case FilePos(LocalFunction(_), f, l, _): "local " + Path.withoutDirectory(f) + ":" + l;
			case FilePos(_, f, l, _): "? " + Path.withoutDirectory(f) + ":" + l;
			case _: "?";
		}
	}

	static function top(s:CallStack, n:Int):String
		return [for (i in 0...(n < s.length ? n : s.length)) item(s[i])].join(" < ");

	static function level2():Array<CallStack> {
		var result:Array<CallStack> = [];
		try {
			result.push(CallStack.callStack());
			result.push(new Exception('').stack);
			result.push(new haxe.ValueException('').stack);
			result.push(new MyError('').stack);
			result.push(new NoCtorError('').stack);
			result.push(@:privateAccess (Exception.thrown(''):Exception).stack);
			result.push(try throw new Exception('') catch (e:Exception) e.stack);
			result.push(try throw new MyError('') catch (e:Exception) e.stack);
			result.push(try throw "value" catch (e:Exception) e.stack);
		} catch (e:Dynamic) {}
		return result;
	}

	static function level1():Array<CallStack> {
		try {
			return level2();
		} catch (e:Dynamic) {
			return null;
		}
	}

	static var sink = 0;

	// (bodies too large to inline)
	static function throw2(n:Int) {
		for (i in 0...n)
			sink += i * 3 + (i % 5 == 0 ? 7 : i % 3 == 0 ? 11 : 13) + (sink > 1000 ? -sink : sink >> 1);
		if (n > 0) throw2(n - 1) else throw "deep";
	}

	static function throw1() {
		for (i in 0...3)
			sink += i * 5 + (i % 2 == 0 ? 17 : i % 7 == 0 ? 19 : 23) + (sink > 1000 ? -sink : sink >> 2);
		throw2(2);
	}

	static function main() {
		for (s in level1())
			trace(top(s, 3));
		try {
			throw1();
		} catch (e:String) {
			trace(top(CallStack.exceptionStack(), 5));
			trace(top(CallStack.exceptionStack(true), 5));
		}
		var local = function() {
			try {
				return CallStack.callStack();
			} catch (e:Dynamic) {
				return null;
			}
		}
		trace(top(local(), 2));
		var f = level1;
		trace(top(f()[0], 3));
		trace(top(new Holder().stack, 2));
		trace(CallStack.callStack().length > 0);
	}
}
