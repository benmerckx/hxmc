package hxmc.com;

// GUIDs' text, "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}", as the four 32-bit
// little-endian words of the GUID struct (Data1, Data2 | Data3 << 16, then
// Data4's bytes): the words hxmc.ir.Com parses an interface's IID into, every
// character checked as it does (32 hexadecimal digits once the braces and
// dashes are dropped)
class Guids {
	public static function parse(s:String):Array<Int> {
		var h = s == null ? "" : StringTools.replace(StringTools.replace(StringTools.replace(s, "{", ""), "}", ""), "-", "");
		var ok = h.length == 32;
		for (i in 0...h.length)
			if ("0123456789abcdefABCDEF".indexOf(h.charAt(i)) < 0) ok = false;
		if (!ok) throw new ComException(ComException.E_INVALIDARG, 'not a GUID: $s');
		function hex(i:Int, n:Int):Int
			return Std.parseInt("0x" + h.substr(i, n));
		function byte(i:Int):Int
			return hex(16 + 2 * i, 2);
		return [
			hex(0, 8),
			hex(8, 4) | (hex(12, 4) << 16),
			byte(0) | (byte(1) << 8) | (byte(2) << 16) | (byte(3) << 24),
			byte(4) | (byte(5) << 8) | (byte(6) << 16) | (byte(7) << 24)
		];
	}
}
