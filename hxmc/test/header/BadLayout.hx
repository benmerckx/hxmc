// A declaration that disagrees with its header (make header-check: must fail):
// a struct field of the wrong size, a parameter of the wrong width.
// expect: QR.q: q is an integer of 8 bytes
// expect: QR: struct cb_qr has 16 bytes
// expect: cb_value: parameter 1 (o) is an integer of 4 bytes
@:hxmc.struct @:hxmc.cname("struct cb_qr") @:publicFields class QR {
	var q:hxmc.I64;
	var r:hxmc.I64;
}

@:hxmc.c @:hxmc.fast @:hxmc.header("CBindings.h") extern class Lib {
	@:hxmc.len(out, 1) static function cb_divmod(a:Int, b:Int, out:hxmc.Span<QR>):Int;
	static function cb_value(o:Int):Int;
}

class BadLayout {
	@:hxmc.unsafe @:hxmc.kernel static function divide(a:Int, b:Int):Int {
		var qr:hxmc.Span<QR> = hxmc.Span.stack(1);
		return Lib.cb_divmod(a, b, qr) + Lib.cb_value(0);
	}

	static function main()
		trace(divide(7, 2));
}
