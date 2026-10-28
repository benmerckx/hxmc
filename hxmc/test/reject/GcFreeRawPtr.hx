// Without @:hxmc.unsafe, GC-free code reaches no raw memory: no Ptr.
// expect: GcFreeRawPtr.hx:6: GcFreeRawPtr.first: the parameter p has the raw type hxmc.unsafe.Ptr<hxmc.unsafe.UInt8> (gcfree: raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.*;

class GcFreeRawPtr {
	@:hxmc.gcfree static function first(p:Ptr<UInt8>):Int
		return p[0];

	static function main() {
		var b = IoBuffer.alloc(4);
		trace(first(b.ptr));
		b.free();
	}
}
