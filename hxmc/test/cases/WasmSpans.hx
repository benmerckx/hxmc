import haxe.io.Bytes;
import hxmc.Handle;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.*;

// Typed bindings on WebAssembly (docs/interop.md, "Typed bindings"): a
// span is two i32s of the import (its address and its length), a span with
// @:hxmc.len its address alone, an out-struct a span of one, a handle its
// value; WasmSpans.cjs is the host. WebAssembly only.
@:hxmc.struct @:publicFields class MinMax {
	var lo:Int32;
	var hi:Int32;
}

@:hxmc.handle(0) abstract Obj(Int) {}

@:hxmc.lib("host") @:hxmc.c @:hxmc.fast @:hxmc.safe extern class Host {
	static function h_sum(p:ReadOnlySpan<UInt8>):Int;
	@:hxmc.len(p, n) static function h_fill(p:Span<UInt8>, v:Int, n:Int):Void;
	@:hxmc.len(out, 1) static function h_minmax(p:ReadOnlySpan<Int>, out:Span<MinMax>):Void;
	static function h_open(v:Int):Obj;
	@:hxmc.close(o) static function h_close(o:Obj):Int;
}

class WasmSpans {
	@:hxmc.kernel static function range():Int {
		var xs:Span<Int> = Span.stack(5);
		for (i in 0...5)
			xs[i] = (i * 7) % 5 - 2;
		var mm:Span<MinMax> = Span.stack(1);
		Host.h_minmax(xs, mm);
		return mm[0].lo * 100 + mm[0].hi;
	}

	@:hxmc.kernel static function handles(v:Int):Int {
		var o = Host.h_open(v);
		if (!Handle.valid(o)) return -1;
		var r = Host.h_close(o);
		return Handle.valid(o) ? -2 : r;
	}

	static function main() {
		var b = Bytes.ofString("abcdef");
		trace(Host.h_sum(ReadOnlySpan.ofBytes(b)), Host.h_sum(ReadOnlySpan.ofBytes(b, 2, 2)));
		Host.h_fill(Span.ofBytes(b), 48, 4);
		trace(b.toString());
		trace(range(), handles(3), handles(0));
	}
}
