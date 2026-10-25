// `@:try e` (docs/plans/lowlevel.md, "Less to write"): a scoped error value
// returned at once, the value of Ok given otherwise.
import hxmc.scoped.*;

@:hxmc.scoped enum Digit {
	Ok(v:Int);
	Bad(at:Int);
	Empty;
}

@:hxmc.scoped enum Sum {
	Ok(total:Int);
	Bad(at:Int);
	Empty;
}

@:hxmc.scoped enum Done {
	Ok;
	Bad(at:Int);
	Empty;
}

@:hxmc.scoped class Code {
	static function digit(s:Str, i:Int):Digit {
		if (i >= s.length) return Empty;
		var c = s[i];
		return c >= "0".code && c <= "9".code ? Ok(c - "0".code) : Bad(i);
	}

	// the same errors, another value
	public static function sum(s:Str, n:Int):Sum {
		var t = 0;
		for (i in 0...n)
			t += @:try digit(s, i);
		return Ok(t);
	}

	// no value: a statement
	public static function check(s:Str):Done {
		@:try sum(s, s.length);
		return Ok;
	}

	public static function show(r:Sum):Int
		return switch r {
			case Ok(t): t;
			case Bad(at): -100 - at;
			case Empty: -1;
		}

	public static function shown(r:Done):Int
		return switch r {
			case Ok: 0;
			case Bad(at): -100 - at;
			case Empty: -1;
		}
}

class ScopedTry {
	static function main() {
		trace(Code.show(Code.sum("1234", 4)));
		trace(Code.show(Code.sum("12x4", 4)));
		trace(Code.show(Code.sum("12", 4)));
		trace(Code.shown(Code.check("987")));
		trace(Code.shown(Code.check("9a7")));
	}
}
