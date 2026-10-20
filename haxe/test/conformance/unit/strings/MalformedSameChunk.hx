package unit.strings;

// A syntax error before a byte that is not UTF-8 (0xE6, in the comment at
// the end) within the first 512 characters: upstream's lexer decodes them at
// once, so the file is malformed before any token.
class MalformedSameChunk {
	static function main() {
		var x = ;
	}
}
// æ
