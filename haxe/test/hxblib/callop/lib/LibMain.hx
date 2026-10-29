import p.Api.*;

class LibMain {
	static function main() {
		var s = sig(1);
		s(2);
		s(c -> c + 1);
		trace(s());
	}
}
