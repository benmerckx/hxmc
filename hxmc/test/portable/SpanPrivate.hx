import hxmc.Span;
import hxmc.unsafe.UInt8;

// A span reinterpreted to a private struct: the element's zeroed object was
// made through the struct's path, which for a private type names nothing
// ("Unknown identifier : spanprivate"); this module's own private struct too.
// expect: SpanPrivate.hx:26: 4421,16
// expect: SpanPrivate.hx:27: 7,8
@:hxmc.struct @:publicFields private class Mine {
	var a:Int;
	var b:Int;

	function new() {}
}

class SpanPrivate {
	@:hxmc.kernel static function mine(s:Span<UInt8>):Int {
		var m:Span<Mine> = s.reinterpret();
		m[1].a = 7;
		m.blit(0, m, 1, 1);
		return m[0].a;
	}

	static function main() {
		var b = haxe.io.Bytes.alloc(64);
		trace(spanprivate.Kern.run(Span.ofBytes(b)), spanprivate.Kern.size());
		trace(mine(Span.ofBytes(b)), hxmc.unsafe.Struct.sizeOf(Mine));
	}
}
