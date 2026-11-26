import haxe.CallStack;

// A throw's stack through a rethrow and a fault (hxmc.rt.Stacks, Start,
// Faults): `throw e` of a caught value, while the function that caught it
// runs, goes on from its throw's stack (Start.throwValue), caught again and
// uncaught (a child process: the uncaught report prints the recorded throw,
// Stacks.reportThrow); a null access on an instruction that starts its line
// is named on that line (Faults.redirect: the return address one past the
// faulting instruction). Each line prints the first frames as method:line;
// the functions have bodies too large to inline (an inlined frame is its
// caller's).
class ThrowStacks {
	static var sink = 0;

	static function top(s:CallStack, n:Int):String {
		var r = [];
		for (i in s)
			switch i {
				case FilePos(Method(_, m), _, l, _) if (r.length < n): r.push(m + ":" + l);
				case _:
			}
		return r.join(" < ");
	}

	static function fail(n:Int) {
		for (i in 0...n)
			sink += i * 3 + (i % 5 == 0 ? 7 : i % 3 == 0 ? 11 : 13) + (sink > 1000 ? -sink : sink >> 1);
		throw "boom";
	}

	static function rethrow() {
		try {
			fail(3);
		} catch (e:String) {
			// (allocations: a collection may move the value in between)
			sink += [for (i in 0...2000) [i]].length;
			throw e;
		}
	}

	static function length(a:Array<Int>):Int {
		for (i in 0...3)
			sink += i * 5 + (i % 2 == 0 ? 17 : i % 7 == 0 ? 19 : 23) + (sink > 1000 ? -sink : sink >> 2);
		return a.length;
	}

	static function main() {
		if (Sys.args()[0] == "uncaught") {
			rethrow();
			return;
		}
		try {
			rethrow();
		} catch (e:String) {
			trace(e, top(CallStack.exceptionStack(), 3));
		}
		try {
			sink += length(sink > -1 ? null : [1]);
		} catch (e:String) {
			trace(e, top(CallStack.exceptionStack(), 2));
		}
		var p = new sys.io.Process(Sys.programPath(), ["uncaught"]);
		var err = p.stderr.readAll().toString();
		var code = p.exitCode();
		p.close();
		var re = ~/^Called from ThrowStacks\.(\w+) \(.*line ([0-9]+)\)$/;
		trace(code, [for (l in err.split("\n")) if (re.match(l)) re.matched(1) + ":" + re.matched(2)].join(" < "));
	}
}
