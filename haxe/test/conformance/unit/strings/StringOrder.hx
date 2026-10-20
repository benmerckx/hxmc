package unit.strings;

// OCaml compares strings by their UTF-8 bytes, which is code point order:
// a character past U+FFFF (a surrogate pair in UTF-16) sorts after one from
// U+E000 to U+FFFF, where UTF-16 code units sort it before.
class StringOrder {
	static function name(s:String):String {
		return switch s {
			case "\u{1F600}": "grinning";
			case "\u{E000}": "private";
			case "\u{10000}": "linear b";
			case "\u{FFFD}": "replacement";
			case "a": "a";
			case _: "other";
		}
	}

	static function main() {
		var o = {"\u{1F600}": 1, "\u{E000}": 2, "a": 3, "\u{10000}": 4, "\u{FFFD}": 5};
		var fields = Reflect.fields(o);
		fields.sort(Reflect.compare);
		for (f in fields) Sys.println(name(f) + " " + Reflect.field(o, f));
		Sys.println("\u{E000}" < "\u{1F600}");
	}
}
