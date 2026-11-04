package hxmc.com;

// GUIDs' text, "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}", as the four 32-bit
// little-endian words of the GUID struct (Data1, Data2 | Data3 << 16, then
// Data4's bytes): the words hxmc.ir.Com parses an interface's IID into
class Guids {
	public static function parse(s:String):Array<Int> {
		var h = StringTools.replace(StringTools.replace(StringTools.replace(s, "{", ""), "}", ""), "-", "");
		if (h.length != 32) throw new ComException(ComException.E_INVALIDARG, 'not a GUID: $s');
		function hex(i:Int, n:Int):Int {
			var v = Std.parseInt("0x" + h.substr(i, n));
			if (v == null) throw new ComException(ComException.E_INVALIDARG, 'not a GUID: $s');
			return v;
		}
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
