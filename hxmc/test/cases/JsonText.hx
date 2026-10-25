// haxe.Json's strings (hxmc's JsonPrinter.quote, StringBuf.addJsonString;
// JsonParser.parseString over hxmc.rt.Str.jsonRun): escapes at every
// position of a word of four units, runs longer than a word, non-ASCII and
// surrogates, \u escapes, and the errors (an unclosed string, a 0 unit);
// StringBuf.addSub's ranges, copied without a substring.
class JsonText {
	static function main() {
		var samples = [
			"", "a", "ab\"", "abc\"", "abcd\"", "abcde\\", "\"\"\"\"\"", "\\\\\\\\", "line\nbreak", "tab\there", "cr\rlf\n", "\x08bs\x0Cff",
			"plain text longer than a few words of four units each, with no escape at all", "é ü ñ 中文 😀 end", "ctl\x01\x1Fchars", "mixed \"q\" and \\b\\ and \n",
		];
		for (s in samples) {
			var j = haxe.Json.stringify(s);
			var back:String = haxe.Json.parse(j);
			Sys.println(j + " " + (back == s ? "same" : "DIFFERENT"));
		}
		Sys.println(haxe.Json.stringify({a: "x\"y", b: ["1", "two\n"], c: {d: "\\"}}));
		for (src in ['"\\u0041\\u00e9\\ud83d\\ude00"', '"a\\/b"', '{"k": "v", "w": "\\"q\\""}', '"abcdefgh\\"ij"'])
			Sys.println(haxe.Json.stringify(haxe.Json.parse(src)));
		for (bad in ['"abc', '"abcdefgh', '"a\\x"', '"ab' + String.fromCharCode(0) + 'cd"'])
			try {
				haxe.Json.parse(bad);
				Sys.println("parsed: " + bad.length);
			} catch (e:Dynamic) {
				Sys.println("error: " + e);
			}
		var b = new StringBuf();
		for (r in [[0, 3], [2, -1], [-3, 2], [-20, 4], [5, 100], [12, 1], [3, 0], [4, -10]])
			b.addSub("abcdefghij", r[0], r[1]);
		b.addSub("tail", 1);
		b.addSub("tail", -2);
		Sys.println(b.toString() + " " + b.length);
	}
}
