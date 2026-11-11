import hxmc.ReadOnlySpan;
import hxmc.rt.StrView;
import hxmc.unsafe.UInt16;
import hxmc.unsafe.UInt8;

// A kernel lent GC values (docs/interop.md, "Kernels"): it holds them in
// locals, passes and returns them, compares them with null, and reads a
// string through its view (hxmc.rt.StrView), every unit checked.
class KernelLoans {
	@:hxmc.kernel static function count(s:String, u:Int):Int
		return StrView.isNull(s) ? -1 : StrView.isOne(s) ? count1(StrView.units1(s), u) : count2(StrView.units2(s), u);

	@:hxmc.kernel static function count1(c:ReadOnlySpan<UInt8>, u:Int):Int {
		var n = 0;
		for (i in 0...c.length)
			if ((c[i] : Int) == u) n++;
		return n;
	}

	@:hxmc.kernel static function count2(c:ReadOnlySpan<UInt16>, u:Int):Int {
		var n = 0;
		for (i in 0...c.length)
			if ((c[i] : Int) == u) n++;
		return n;
	}

	@:hxmc.kernel static function longer(a:String, b:String):String
		return b == null || StrView.length(a) >= StrView.length(b) ? a : b;

	static function main() {
		trace(count("banana", "a".code), count("añana€", "a".code), count(null, 0));
		trace(longer("ab", "abc"), longer("abc", null));
		trace("x" == "x", "ab" + "c" == "abc", "b" < "c", "añb".indexOf("b"), "abcabc".lastIndexOf("bc"), "€x€".indexOf("x"));
		var h = new Map<String, Int>();
		h.set("k" + 1, 7);
		trace(h.get("k1"), Reflect.compare("a€", "a"));
		var b = new StringBuf();
		b.add("añ€");
		var n = b.length;
		b.clear();
		b.add("x");
		trace(n, b.length, b.toString());
	}
}
