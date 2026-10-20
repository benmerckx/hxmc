package unit.strings;

// OCaml strings are bytes: bytes that are not UTF-8, read by a macro, reach
// the typed AST and the outputs as they are (malformed.txt: a lone lead
// byte, sequences cut short, a stray continuation byte, 0xFF, a surrogate's,
// an overlong and a past-U+10FFFF encoding).
class Malformed {
	static macro function read() {
		var file = haxe.macro.Context.resolvePath("unit/strings/malformed.txt");
		return macro $v{sys.io.File.getContent(file)};
	}

	static function main() {
		var s = read();
		Sys.println(s);
		Sys.println(s + "!");
		var b = haxe.io.Bytes.ofString(s);
		Sys.println(b.toHex());
		Sys.println(haxe.Utf8.validate(s));
		try Sys.println(b.toString()) catch (e:Dynamic) Sys.println(e);
	}
}
