// Nor a handle to raw memory: hxmc.unsafe's IoBuffer, or an abstract over a Ptr.
// expect: GcFreeHandle.hx:9: GcFreeHandle.size: the parameter b has the raw type hxmc.unsafe.IoBuffer (gcfree: raw memory needs @:hxmc.unsafe)
// expect: GcFreeHandle.hx:9: GcFreeHandle.size: the parameter h has the raw type Handle (gcfree: raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.*;

abstract Handle(Ptr) {}

class GcFreeHandle {
	@:hxmc.gcfree static function size(b:IoBuffer, h:Handle):Int
		return 0;

	static function main() {
		var b = IoBuffer.alloc(4);
		trace(size(b, cast b));
		b.free();
	}
}
