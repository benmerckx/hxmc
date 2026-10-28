// define: dce=full
import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Struct;
import hxmc.unsafe.UInt8;

// Spans and structs under --dce full: DCE kept only the struct fields the
// typed code reaches, so hxmc.Span's SpanData (ptr is FnLower.spanCall's
// only) lost ptr and any span failed to compile ("@:hxmc.struct SpanData
// has no field ptr"), and a struct with a field nothing names lost it and
// its layout with it (Rec's b read at a's neighbour). Every variable of a
// struct is kept with its class (CInterop.keepFields).
@:hxmc.struct @:publicFields class Rec {
	var a:Int;
	var reserved:Int; // never named: still four bytes
	var b:Int;

	function new() {}
}

@:hxmc.struct @:publicFields class Untouched {
	var x:Int;
	var y:Float;
}

class SpanDce {
	// an element, without the length
	@:hxmc.kernel static function at(s:ReadOnlySpan<UInt8>, i:Int):Int
		return s[i];

	@:hxmc.kernel static function first(s:Span<UInt8>):Int
		return s.length > 0 ? s[0] : -1;

	// the third Int of a Rec, written as bytes
	@:hxmc.kernel static function recB(s:Span<UInt8>):Int {
		var r:Span<Rec> = s.reinterpret();
		r[0].a += 1;
		return r[0].b * 100 + r[0].a;
	}

	@:hxmc.kernel static function fill(s:Span<UInt8>):Int {
		s.sub(1, 2).fill(0, 2, 7);
		return s[0] + s[1] + s[2] + s[3];
	}

	static function main() {
		var b = Bytes.alloc(12);
		for (i in 0...12)
			b.set(i, i + 1);
		trace(first(Span.ofBytes(b)), at(ReadOnlySpan.ofBytes(b), 5));
		b.setInt32(0, 4);
		b.setInt32(8, 9);
		trace(recB(Span.ofBytes(b)), b.getInt32(0), Struct.sizeOf(Rec), Struct.sizeOf(Untouched));
		trace(fill(Span.ofBytes(b, 4, 4)));
	}
}
