// A span is never a field: it would outlive the call that lends its memory.
// expect: SpanField.hx:8: the field last has a span type (kernel: spans live in parameters and locals only)
import hxmc.Span;
import hxmc.unsafe.UInt8;

class Holder {
	public function new() {}
	public var last:Span<UInt8>;
}

class SpanField {
	static function main()
		trace(new Holder() != null);
}
