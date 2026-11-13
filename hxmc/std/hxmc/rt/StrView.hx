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

	// the hash kept in the header (0: not computed yet: Str.hash)
	public static function storedHash(s:String):Int
		return Repr.storedHash(s);

	// (a benign race between threads: they store the same value)
	public static function storeHash(s:String, h:Int)
		Repr.storeHash(s, h);

	// a one-byte string's bytes from its stored hash on (its hash, its length,
	// then its units: unit i at 8 + i): a word that ends in a short string's
	// units starts before them (Str.hashSlow)
	public static function window1(s:String):ReadOnlySpan<UInt8>
		return ReadOnlySpan.unsafeOf((cast Mem.addr(s).add(-4) : Ptr<UInt8>), Repr.len(s) + 8);

	// a and b of the same width and length, with the same units
	public static function sameUnits(a:String, b:String):Bool {
		var n = Repr.len(a), one = Repr.isOne(a);
		if (n != Repr.len(b) || one != Repr.isOne(b)) return false;
		return MemOps.compareAt(Mem.addr(a).add(4), Mem.addr(b).add(4), one ? (n : I64) : (2 * n : I64)) == 0;
	}
}
