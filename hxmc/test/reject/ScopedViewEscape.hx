// The root checker follows what a result holds: the words of a string are views of it, so they cannot outlive it.
// expect: ScopedViewEscape.hx:25: Code.run: storing a reference rooted at tmp (made at line 23, memory of that scope) into keep, which outlives it
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	static function words(s:Str):Grow<Str> {
		var g = new Grow<Str>();
		var start = 0;
		for (i in 0...s.length + 1)
			if (i == s.length || s[i] == " ".code) {
				if (i > start) g.push(s.sub(start, i - start));
				start = i + 1;
			}
		return g;
	}

	public static function run():Int {
		var keep:Str = "";
		var lit:Str = "kept as a literal";
		for (k in 0...3) {
			var ws = words(lit);
			keep = ws[0];
			var tmp = Str.copy("copied text");
			var vs = words(tmp);
			keep = vs[1];
		}
		return keep.length;
	}
}

class ScopedViewEscape {
	static function main()
		trace(Code.run());
}
