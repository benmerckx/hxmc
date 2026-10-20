package unit.strings;

// A syntax error before a byte that is not UTF-8 (0xE6, in the comment past
// 512 characters): upstream's lexer decodes 512 characters at a time and
// reaches the byte only when it needs that chunk, so the syntax error wins.
class MalformedAfterError {
	static function main() {
		var x = ;
	}
}

// filler line 0 of a comment that is long enough to cross 512 characters
// filler line 1 of a comment that is long enough to cross 512 characters
// filler line 2 of a comment that is long enough to cross 512 characters
// filler line 3 of a comment that is long enough to cross 512 characters
// filler line 4 of a comment that is long enough to cross 512 characters
// filler line 5 of a comment that is long enough to cross 512 characters
// filler line 6 of a comment that is long enough to cross 512 characters
// filler line 7 of a comment that is long enough to cross 512 characters
// filler line 8 of a comment that is long enough to cross 512 characters
// filler line 9 of a comment that is long enough to cross 512 characters
// æ
