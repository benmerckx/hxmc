// Nor a struct's field: a struct value may be returned to GC code and stored anywhere.
// expect: the field view of the struct Wrapped has a span type (gcfree: spans live in parameters and locals only)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

@:hxmc.struct @:publicFields class Wrapped {
	var view:ReadOnlySpan<UInt8>;
	var n:Int;
	function new() {}
}

class SpanStructField {
	@:hxmc.gcfree static function wrap(s:ReadOnlySpan<UInt8>):Wrapped {
		var w = new Wrapped();
		w.view = s;
		return w;
	}

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(wrap(ReadOnlySpan.ofBytes(b)).n);
	}
}
