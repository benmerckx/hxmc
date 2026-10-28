package spanprivate;

import hxmc.Span;
import hxmc.unsafe.Struct;
import hxmc.unsafe.UInt8;

// (SpanPrivate's kernel: a private struct of a module in a package, whose
// path, spanprivate._Kern.State, no expression names)
class Kern {
	@:hxmc.kernel public static function run(scratch:Span<UInt8>):Int {
		var st:Span<State> = scratch.reinterpret();
		st[0].n = 41;
		st[0].n += 1;
		st[1].f = 0.5;
		st.blit(2, st, 0, 1);
		return st[2].n * 10 + Std.int(st[1].f * 2) + st.length * 1000;
	}

	public static function size():Int
		return Struct.sizeOf(State);
}

@:hxmc.struct @:publicFields private class State {
	var n:Int;
	var f:Float;

	function new() {}
}
