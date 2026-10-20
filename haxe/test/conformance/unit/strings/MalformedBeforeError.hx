package unit.strings;

// A byte that is not UTF-8 (0xE6: æ) before a syntax error: the file is
// malformed.
class MalformedBeforeError {
	static function main() {
		var x = ;
	}
}
