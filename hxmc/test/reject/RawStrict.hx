// -D hxmc.strict: raw memory outside @:hxmc.unsafe code is an error.
// define: hxmc.strict
// expect: RawStrict.peek: a call of hxmc.unsafe.Mem.getI32 (raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.*;

class RawStrict {
	static function peek(o:Dynamic):Int
		return Mem.getI32(Mem.addr(o), 0);

	static function main()
		trace(peek("x"));
}
