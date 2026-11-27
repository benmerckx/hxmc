// Closure calls' effects (hxmc/src/hxmc/ir/Closures.hx): what a closure call
// may run is followed from where closures are made, through locals,
// parameters, fields, captures, statics and results; through Dynamic,
// arrays, structures, reflection and type parameters it is any closure that
// escaped. Each call writes something read before and after it.
class Counter {
	public var n = 0;
	public var f:Void->Void;

	public function new() {}
}

class ClosureEffects {
	static var hook:Void->Void;
	static var total = 0;

	static function twice(c:Counter, g:Void->Void):Int {
		var s = 0;
		for (i in 0...2) {
			s += c.n;
			g();
			s += c.n;
		}
		return s;
	}

	static function viaDynamic(c:Counter, d:Dynamic):Int {
		var before = c.n;
		var g:Void->Void = d;
		g();
		return before * 100 + c.n;
	}

	static function generic<T>(x:T, k:T->Void):Void
		k(x);

	static function main() {
		var c = new Counter();
		Sys.println('param: ${twice(c, () -> c.n += 3)} ${c.n}');
		c.f = () -> c.n *= 2;
		var s = 0;
		for (i in 0...3) {
			s += c.n;
			c.f();
		}
		Sys.println('field: $s ${c.n}');
		hook = () -> total += c.n;
		var t0 = total;
		hook();
		Sys.println('static: $t0 $total');
		Sys.println('dynamic: ${viaDynamic(c, () -> c.n = 7)}');
		var fs:Array<Void->Void> = [() -> c.n++, () -> c.n += 10];
		var before = c.n;
		for (g in fs)
			g();
		Sys.println('array: $before ${c.n}');
		var o:Dynamic = {run: () -> c.n = -1};
		var b2 = c.n;
		o.run();
		Sys.println('structure: $b2 ${c.n}');
		var r:Void->Void = Reflect.field({k: () -> c.n = 42}, "k");
		var b3 = c.n;
		r();
		Sys.println('reflection: $b3 ${c.n}');
		var b4 = c.n;
		generic(c, (x:Counter) -> x.n = 5);
		Sys.println('type parameter: $b4 ${c.n}');
		var any:Any = () -> c.n = 9;
		var b5 = c.n;
		(cast any : Void->Void)();
		Sys.println('cast: $b5 ${c.n}');
	}
}
