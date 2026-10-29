import callop.Api.*;

// Overloaded call operators (@:op(a())) of abstracts, one taking a function
// called with a lambda, from a module-level function and a class: in another
// module (callop.Sig, read back from the case's HXB archive, whose impl
// classes' statics are also the operators' overloads) and in this one.
abstract Local<T>(Array<T>) {
	public inline function new(v:T) this = [v];

	@:op(a()) inline function read():T return this[0];

	@:op(a()) function update(f:T->T):Void this[0] = f(this[0]);

	@:op(a()) inline function write(v:T):Void this[0] = v;
}

function run() {
	var s = sig(1);
	s(2);
	s(c -> c + 1);
	s(5);
	trace(s());
	var s = sigFirst(1);
	s(2);
	s(c -> c * 10);
	trace(s());
	var s = sigPlain("a");
	s(c -> c + "b");
	trace(s());
	s("c");
	trace(s());
	var s = sigPlainFirst(7);
	s(c -> c - 1);
	trace(s());
	var l = new Local(1.5);
	l(c -> c * 2);
	trace(l());
}

class CallOpOverloads {
	static function main() {
		run();
		var s = sig(1);
		s(2);
		s(c -> c + 1);
		s(5);
		trace(s());
		var s = sigFirst("x");
		s(c -> c + c);
		trace(s());
		var s = sigPlain(3);
		s(4);
		s(c -> c * c);
		trace(s());
		var s = sigPlainFirst(true);
		s(c -> !c);
		trace(s());
		var l = new Local("l");
		l("m");
		l(c -> c + "n");
		trace(l());
	}
}
