package hxmc.rt;

import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.rt.Repr;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt16;
import hxmc.unsafe.UInt8;

// A string's layout (hxmc.rt.Str: its length, its units)
// read for kernels: the one place that trusts it. A kernel is lent the
// string (nothing collects while it runs) and reads it here: its units as
// a span as long as the string, so every access past them is checked.
@:keep @:hxmc.kernel @:hxmc.unsafe
class StrView {
	public static function isNull(s:String):Bool
		return Repr.isNull(s);

	public static function same(a:String, b:String):Bool
		return Repr.same(a, b);

	public static function length(s:String):Int
		return Repr.len(s);

	// a byte per unit (units1), else two (units2)
	public static function isOne(s:String):Bool
		return Repr.isOne(s);

	public static function units1(s:String):ReadOnlySpan<UInt8>
		return ReadOnlySpan.unsafeOf((cast Repr.chars1(s) : Ptr<UInt8>), Repr.len(s));

	public static function units2(s:String):ReadOnlySpan<UInt16>
		return ReadOnlySpan.unsafeOf((cast Repr.chars2(s) : Ptr<UInt16>), Repr.len(s));

	// a and b of the same width and length, with the same units
	public static function sameUnits(a:String, b:String):Bool {
		var n = Repr.len(a), one = Repr.isOne(a);
		if (n != Repr.len(b) || one != Repr.isOne(b)) return false;
		return MemOps.compare(Mem.addr(a).add(4), Mem.addr(b).add(4), one ? (n : I64) : (2 * n : I64)) == 0;
	}
}
