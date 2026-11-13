// A kernel writes statics of plain values only: a raw address kept in a static is raw memory.
// expect: KernelStaticPtr.hx:9: KernelStaticPtr.keep: a write of the static at of the type hxmc.unsafe.Ptr<Void> (kernel: a kernel writes statics of plain values only)
import hxmc.unsafe.Ptr;

class KernelStaticPtr {
	static var at:Ptr;

	@:hxmc.kernel static function keep(i:Int):Int {
		at = Ptr.nil();
		return i;
	}

	static function main()
		trace(keep(1));
}
