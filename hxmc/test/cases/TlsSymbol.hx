class TlsSymbol {
	static function main() {
		if (hxmc.rt.TestTlsSymbol.read() != 0) throw "TLS not zeroed";
		hxmc.rt.TestTlsSymbol.write(42);
		if (hxmc.rt.TestTlsSymbol.read() != 42) throw "wrong TLS value";
		Sys.println("ok");
	}
}
