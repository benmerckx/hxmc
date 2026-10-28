// A read-only span cannot be written through, also not a struct element's field.
// expect: SpanReadOnlyWrite.hx:14: SpanReadOnlyWrite.reset: a write through a read-only span (kernel: a ReadOnlySpan cannot be written through)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.Ptr;

@:hxmc.struct @:publicFields class Cell {
	var v:Int;
}

class SpanReadOnlyWrite {
	@:hxmc.kernel static function reset(s:ReadOnlySpan<Cell>):Int {
		var n = s.length;
		s[0].v = 0;
		return n;
	}

	static function main() {
		var buf = IoBuffer.alloc(16);
		trace(reset(ReadOnlySpan.unsafeOf((cast buf.ptr : Ptr<Cell>), 4)));
		buf.free();
	}
}
