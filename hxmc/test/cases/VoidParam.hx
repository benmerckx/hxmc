// A closure whose parameter is of type Void (a C<Void>'s T->Void callback,
// upstream's unit test Issue9678): WebAssembly's linker found no value type
// for it ("wasm: type ?"); it is an i32 there, which calls pass as 0.
private class C<T> {
	final v:T;

	public function new(v:T)
		this.v = v;

	public function next<S>(f:() -> S):C<S>
		return new C(f());

	public function handle(cb:T->Void) {
		cb(v);
	}
}

class VoidParam {
	@:keep static function explicitVoidArg(arg:Void) {}

	static function main() {
		var called = 0;
		function returnVoid() {
			called++;
		}
		new C(42).next(returnVoid).handle(_ -> called++);
		Sys.println(called);
	}
}
