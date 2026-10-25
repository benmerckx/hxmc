// The root checker: a store of one argument into another's memory, from the callee's summary, checked where it is called.
// expect: ScopedCallStore.hx:13: Code.run: Code.put stores its argument s into the memory of its argument g: storing a reference rooted at s (made at line 12, memory of that scope) into memory rooted at g (made at line 10, memory of the function), which outlives it
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	static function put(g:Grow<Str>, s:Str)
		g.push(s);

	public static function run():Int {
		var g = new Grow<Str>();
		for (i in 0...3) {
			var s = Str.copy("x");
			put(g, s);
		}
		return g.length;
	}
}

class ScopedCallStore {
	static function main()
		trace(Code.run());
}
