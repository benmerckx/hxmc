// GC code returns no scoped value holding references: it copies it out, or the function is scoped.
// expect: ScopedGcReturn.hx:7: ScopedGcReturn.word: GC code returns no scoped value holding references
import hxmc.scoped.*;

class ScopedGcReturn {
	static function word(s:String):Str
		return Str.copyOf(s);

	static function main()
		trace(word("text").length);
}
