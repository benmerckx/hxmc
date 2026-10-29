import p.Api.*;

// The same calls from a class, and an abstract with overloaded call
// operators of this module.
abstract Local<T>(Array<T>) {
	public inline function new(v:T) this = [v];

	@:op(a()) inline function read():T return this[0];

	@:op(a()) function update(f:T->T):Void this[0] = f(this[0]);

	@:op(a()) inline function write(v:T):Void this[0] = v;
}

class Main {
	static function main() {
		Use.run();
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
		l(c -> c + "n");
		trace(l());
	}
}
