// A declaration that disagrees with its header (make native-check NATIVE=header: must fail):
// a struct field of the wrong size, a parameter of the wrong width, a second
// declaration of a function with a span too short for what C writes, a span
// of bytes whose length C counts in structs, passed alone or with its count.
// expect: QR.q: q is an integer of 8 bytes
// expect: QR: struct cb_qr has 16 bytes
// expect: cb_value: parameter 1 (o) is an integer of 4 bytes
// expect: cb_divmod: out (4 bytes) holds what C writes there
// expect: BadLayout.hx:23: cb_qr_sum: parameter 1 (p) is a pointer to an integer of 1 bytes
// expect: BadLayout.hx:27: cb_qr_sum: parameter 1 (p) is a pointer to an integer of 1 bytes
@:hxmc.struct @:hxmc.cname("struct cb_qr") @:publicFields class QR {
	var q:hxmc.I64;
	var r:hxmc.I64;
}

@:hxmc.c @:hxmc.fast @:hxmc.header("CBindings.h") extern class Lib {
	@:hxmc.len(out, 1) static function cb_divmod(a:Int, b:Int, out:hxmc.Span<QR>):Int;
	static function cb_value(o:Int):Int;
}

@:hxmc.c @:hxmc.fast @:hxmc.header("BadLayout.h") extern class Lib2 {
	@:hxmc.len(out, 1) static function cb_divmod(a:Int, b:Int, out:hxmc.Span<Int>):Int;
	static function cb_qr_sum(p:hxmc.Span<hxmc.unsafe.UInt8>):Int;
}

@:hxmc.c @:hxmc.fast @:hxmc.header("BadLayout.h") extern class Lib3 {
	@:hxmc.len(p, n) static function cb_qr_sum(p:hxmc.Span<hxmc.unsafe.UInt8>, n:hxmc.unsafe.USize):Int;
}

class BadLayout {
	@:hxmc.unsafe @:hxmc.kernel static function divide(a:Int, b:Int):Int {
		var qr:hxmc.Span<QR> = hxmc.Span.stack(1);
		var n:hxmc.Span<Int> = hxmc.Span.stack(1);
		var bytes:hxmc.Span<hxmc.unsafe.UInt8> = hxmc.Span.stack(8);
		return Lib.cb_divmod(a, b, qr) + Lib.cb_value(0) + Lib2.cb_divmod(a, b, n) + Lib2.cb_qr_sum(bytes) + Lib3.cb_qr_sum(bytes, 8);
	}

	static function main()
		trace(divide(7, 2));
}
