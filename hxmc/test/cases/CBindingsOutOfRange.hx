import hxmc.Span;
import hxmc.unsafe.*;

// A typed C call whose count exceeds its span (docs/interop.md, "Typed
// bindings"): checked at the call, so C never sees it; the program ends
// (exit 2) with a message on stderr naming the count, the length and the
// call. CBindings.c is the C side.
@:hxmc.c @:hxmc.fast @:hxmc.safe extern class Lib {
	@:hxmc.len(p, n) static function cb_fill(p:Span<UInt8>, v:Int, n:USize):Void;
}

class CBindingsOutOfRange {
	@:hxmc.kernel static function fill(n:Int):Int {
		var s:Span<UInt8> = Span.stack(8);
		Lib.cb_fill(s, 1, n);
		return s[n - 1];
	}

	static function main() {
		trace(fill(8));
		Sys.stdout().flush();
		trace(fill(9));
		trace("not reached");
	}
}
