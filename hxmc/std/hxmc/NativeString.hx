package hxmc;

// Strings' representation (hxmc.rt.Str), for code that orders strings by code
// point while Haxe's `<` orders UTF-16 units (the port's core.ds.Key.compareStrings):
// a one-byte string's units are all below 256, where the two orders agree.
@:allow(hxmc.rt)
class NativeString {
	// whether every unit of s is below 256 (s is stored one byte per unit)
	public static inline function isOneByte(s:String):Bool
		return hxmc.rt.Str.isOne(s);

	// the order of a and b by their units (-1, 0 or 1), as `<`: one runtime compare
	public static inline function compareUnits(a:String, b:String):Int
		return @:privateAccess hxmc.rt.Str.cmp(a, b);
}
