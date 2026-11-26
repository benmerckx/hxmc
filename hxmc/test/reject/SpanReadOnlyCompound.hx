// A compound assignment through a read-only span's element is a write.
// expect: SpanReadOnlyCompound.hx:15: SpanReadOnlyCompound.k: a write through a read-only span
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

@:hxmc.struct @:publicFields class RS {
	var n:Int;

	function new() {}
}

class SpanReadOnlyCompound {
	@:hxmc.kernel static function k(raw:ReadOnlySpan<UInt8>):Int {
		var st:ReadOnlySpan<RS> = raw.reinterpret();
		st[0].n += 1;
		return st[0].n;
	}

	static function main()
		trace(k(ReadOnlySpan.ofBytes(haxe.io.Bytes.alloc(8))));
}
