package unit.strings;

import haxe.macro.Context;

// Context.parse of a string whose bytes are not UTF-8: the lexer's
// Sedlexing.MalFormed is no exception the macro can catch, and the reference
// reports it at no position.
class MalformedParse {
	static macro function parse() {
		var file = Context.resolvePath("unit/strings/malformed.txt");
		var s = sys.io.File.getContent(file);
		return try Context.parse('"' + s + '"', Context.currentPos()) catch (e:Dynamic) macro "caught";
	}

	static function main() {
		Sys.println(parse());
	}
}
