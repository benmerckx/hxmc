package callop;

// The abstracts of CallOpOverloads: overloaded call operators in another
// module, inline and not, in both orders, the function argument's type
// written out or a typedef.
class Cell<T> {
	public var v:T;

	public function new(v) this.v = v;
}

typedef Up<T> = T->T;

abstract Sig<T>(Cell<T>) {
	public inline function new(v:T) this = new Cell(v);

	@:op(a()) inline function read():T return this.v;

	@:op(a()) inline function write(v:T):Void this.v = v;

	@:op(a()) inline function update(f:T->T):Void this.v = f(this.v);
}

abstract SigFirst<T>(Cell<T>) {
	public inline function new(v:T) this = new Cell(v);

	@:op(a()) inline function read():T return this.v;

	@:op(a()) inline function update(f:Up<T>):Void this.v = f(this.v);

	@:op(a()) inline function write(v:T):Void this.v = v;
}

abstract SigPlain<T>(Cell<T>) {
	public function new(v:T) this = new Cell(v);

	@:op(a()) function read():T return this.v;

	@:op(a()) function write(v:T):Void this.v = v;

	@:op(a()) function update(f:Up<T>):Void this.v = f(this.v);
}

abstract SigPlainFirst<T>(Cell<T>) {
	public function new(v:T) this = new Cell(v);

	@:op(a()) function read():T return this.v;

	@:op(a()) function update(f:T->T):Void this.v = f(this.v);

	@:op(a()) function write(v:T):Void this.v = v;
}
