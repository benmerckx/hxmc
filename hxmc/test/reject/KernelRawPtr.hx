// Without @:hxmc.unsafe, a kernel reaches no raw memory: no Ptr.
// expect: KernelRawPtr.hx:6: KernelRawPtr.first: the parameter p has the raw type hxmc.unsafe.Ptr<hxmc.unsafe.UInt8> (kernel: raw memory needs @:hxmc.unsafe)
import hxmc.unsafe.*;

class KernelRawPtr {
	@:hxmc.kernel static function first(p:Ptr<UInt8>):Int
		return p[0];

	static function main() {
		var b = IoBuffer.alloc(4);
		trace(first(b.ptr));
		b.free();
	}
}
