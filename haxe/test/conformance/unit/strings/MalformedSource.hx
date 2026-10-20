package unit.strings;

// A string literal holding a byte that is not UTF-8 (0xE6 alone): the
// reference rejects the file ("Malformed file").
class MalformedSource {
	static function main() {
		Sys.println("xæy");
	}
}
