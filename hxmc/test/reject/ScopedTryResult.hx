// `@:try e` returns e's errors: the function's result has them.
// expect: @:try: an error Parsed.Bad returned from a function whose result is no enum
import hxmc.scoped.*;

@:hxmc.scoped enum Parsed {
	Ok(v:Int);
	Bad(at:Int);
}

@:hxmc.scoped class Code {
	static function parse(i:Int):Parsed
		return i > 0 ? Ok(i) : Bad(i);

	public static function bad(i:Int):Int
		return @:try parse(i);
}

class ScopedTryResult {
	static function main()
		trace(Code.bad(1));
}
