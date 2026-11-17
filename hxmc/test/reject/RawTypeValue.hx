// A type of the raw API as a value is raw: through Dynamic its functions are
// no calls of it.
// define: hxmc.strict
// expect: RawTypeValue.hx:12: characters 19-27
// expect: RawTypeValue.main: the type hxmc.unsafe.BytesPtr as a value and 1 more (raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.Blocking;
import hxmc.unsafe.BytesPtr;

class RawTypeValue {
	static function main() {
		var b = haxe.io.Bytes.alloc(16);
		var p:Dynamic = BytesPtr, k:Dynamic = Blocking;
		p.copyIn(b, 0, haxe.Int64.make(0, 0x10), 16);
		trace(k);
	}
}
