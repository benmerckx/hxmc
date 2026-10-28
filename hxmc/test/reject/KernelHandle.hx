// Nor a handle to raw memory: hxmc.unsafe's IoBuffer, or an abstract over a Ptr.
// expect: KernelHandle.hx:9: KernelHandle.size: the parameter b has the raw type hxmc.unsafe.IoBuffer (kernel: raw memory needs @:hxmc.unsafe)
// expect: KernelHandle.hx:9: KernelHandle.size: the parameter h has the raw type Handle (kernel: raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.*;

abstract Handle(Ptr) {}

class KernelHandle {
	@:hxmc.kernel static function size(b:IoBuffer, h:Handle):Int
		return 0;

	static function main() {
		var b = IoBuffer.alloc(4);
		trace(size(b, cast b));
		b.free();
	}
}
