import hxmc.Out;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Int32;

// Arrays, NULL and handles' out-parameters at typed bindings on WebAssembly
// (docs/interop.md, "Typed bindings"): ofArray copies an Array into linear
// memory for the call (a Span's back after it), null passes 0, an Out<H>
// the address of a slot; WasmTyped.cjs is the host. WebAssembly only.
@:hxmc.struct @:publicFields class Pair {
	var a:Int32;
	var b:Int32;

	inline function new(a:Int, b:Int) {
		this.a = a;
		this.b = b;
	}
}

@:hxmc.handle(0) abstract Obj(Int) {}

@:hxmc.lib("host") @:hxmc.c @:hxmc.fast @:hxmc.safe extern class Host {
	@:hxmc.len(p, n) static function t_dot(p:Null<ReadOnlySpan<Pair>>, n:Int):Int;
	@:hxmc.len(p, n) static function t_swap(p:Span<Pair>, n:Int):Void;
	static function t_open(v:Int, out:Out<Obj>):Int;
	static function t_value(o:Null<Obj>):Int;
}

class WasmTyped {
	static function main() {
		var ps = [new Pair(1, 2), new Pair(3, 4), new Pair(5, 6)];
		trace(Host.t_dot(ReadOnlySpan.ofArray(ps), ps.length), Host.t_dot(null, 0));
		Host.t_swap(Span.ofArray(ps), 2);
		trace([for (p in ps) p.a + ":" + p.b].join(" "));
		var o = new Out<Obj>();
		trace(Host.t_open(7, o), Host.t_value(o.value), Host.t_value(null));
		trace(Host.t_open(0, o), o.value == null);
	}
}
