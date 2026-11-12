import hxmc.Handle;
import hxmc.Out;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Ptr;

// NULL at typed bindings (docs/interop.md, "Typed bindings"): a
// Null<ReadOnlySpan<T>> (`const T * _Nullable`), a Null<F> callback and a
// Null<H> handle pass NULL for null; an hxmc.Out<H> is a handle's
// out-parameter (H *). make native-check NATIVE=header checks the declarations.
@:hxmc.handle(0) abstract Node(Ptr) {}

@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("CBindingsNull.h") extern class N {
	@:hxmc.len(p, n) static function cn_sum(p:Null<ReadOnlySpan<Int>>, n:Int):Int;
	@:hxmc.blocking static function cn_apply(f:Null<Int->Int>, v:Int):Int;
	static function cn_new(v:Int):Node;
	static function cn_value(n:Null<Node>):Int;
	static function cn_child(n:Node, out:Out<Node>):Int;
	@:hxmc.close(n) static function cn_free(n:Node):Void;
}

class CBindingsNull {
	@:hxmc.callback static function twice(v:Int):Int
		return v * 2;

	@:hxmc.kernel static function sum(p:ReadOnlySpan<Int>):Int
		return N.cn_sum(p, p.length) + N.cn_sum(null, 0) + N.cn_apply(null, 100);

	static function main() {
		var x = 21;
		trace(N.cn_sum(ReadOnlySpan.of(x), 1), N.cn_sum(null, 5), sum(ReadOnlySpan.of(x)));
		trace(N.cn_apply(twice, 4), N.cn_apply(null, 4));
		var root = N.cn_new(1);
		trace(N.cn_value(root), N.cn_value(null));
		// the children: a handle of an Out, then none (C stores nothing: null)
		var out = new Out<Node>();
		var n = 0;
		var at = root;
		while (N.cn_child(at, out) == 0) {
			trace("child", N.cn_value(out.value), Handle.valid(out.value));
			at = out.value;
			n++;
		}
		trace(n, N.cn_value(at));
		var none = new Out<Node>();
		trace(N.cn_child(at, none), none.value == null, N.cn_value(none.value));
		N.cn_free(root);
		trace(Handle.valid(root));
	}
}
