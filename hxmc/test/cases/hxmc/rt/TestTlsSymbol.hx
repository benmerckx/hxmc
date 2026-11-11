package hxmc.rt;

// Only generated code's symbol references use this slot; no Haxe field
// access should be needed to make the runtime emit its declaration.
@:keep class TestTlsSymbol {
	@:hxmc.threadLocal("hxmc_test_tls_symbol") static var value:hxmc.unsafe.Ptr;

	@:hxmc.unsafe public static function read():Int
		return hxmc.unsafe.Mem.tlsGet("hxmc_test_tls_symbol").toI64().toInt();

	@:hxmc.unsafe public static function write(v:Int):Void
		hxmc.unsafe.Mem.tlsSet("hxmc_test_tls_symbol", hxmc.unsafe.Ptr.ofI64((v : hxmc.I64)));
}
