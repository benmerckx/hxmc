// String.toUpperCase and toLowerCase beyond ASCII (upstream's unit test
// TestUnicode): hxmc mapped A-Z and a-z only; now Eval's simple mappings of
// the BMP (hxmc.rt.CaseMap), a code unit at a time (astral characters stay).
class UnicodeCase {
	static function main() {
		var words = [
			"ä😂", "Ä😂", "σ", "Σ", "straße", "ǅungla", "Ǆ", "ǆ", "ÿ", "Ÿ", "ı", "İ", "ﬀ", "Ⅻ", "ⓐ", "Ａｂｃ", "Ꙁ", "ꙁ", "ა", "Ⴀ", "Ꭰ", "ꭰ", "𐐀𐐨",
			"Привет, Мир", "Γειά σου Κόσμε", "Ünïcödé", "ĀāĂăĄą", "ƀƁƂƃ"
		];
		for (w in words)
			Sys.println(w + " " + w.toUpperCase() + " " + w.toLowerCase());
		var all = new StringBuf();
		var changed = 0, sum = 0;
		for (c in 0x80...0xD800) {
			var s = String.fromCharCode(c);
			var u = s.toUpperCase().charCodeAt(0), l = s.toLowerCase().charCodeAt(0);
			if (u != c || l != c) {
				changed++;
				sum = (sum * 31 + u * 7 + l) & 0xFFFFFF;
			}
		}
		for (c in 0xE000...0x10000) {
			var s = String.fromCharCode(c);
			var u = s.toUpperCase().charCodeAt(0), l = s.toLowerCase().charCodeAt(0);
			if (u != c || l != c) {
				changed++;
				sum = (sum * 31 + u * 7 + l) & 0xFFFFFF;
			}
		}
		Sys.println(changed + " " + sum);
	}
}
