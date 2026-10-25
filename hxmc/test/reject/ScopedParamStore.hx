// The root checker: a function whose result holds no references resets its scope when it returns, so what it allocates cannot go into its caller's memory.
// expect: ScopedParamStore.hx:8: Code.fill: storing a reference rooted at a temporary (made at line 8, memory of the function) into memory of the caller (g), which outlives it
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	static function fill(g:Grow<Str>) {
		for (i in 0...3)
			g.push(Str.copy("x"));
	}

	public static function run():Int {
		var g = new Grow<Str>();
		fill(g);
		return g.length;
	}
}

class ScopedParamStore {
	static function main()
		trace(Code.run());
}
