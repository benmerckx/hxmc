// A kernel writes statics of plain values only: a GC value stored in a static needs a write barrier, and outlives the loan.
// expect: KernelStaticGc.hx:7: KernelStaticGc.keep: a write of the static last of the type String (kernel: a kernel writes statics of plain values only)
class KernelStaticGc {
	static var last:String;

	@:hxmc.kernel static function keep(s:String):Int {
		last = s;
		return 0;
	}

	static function main()
		trace(keep("x"));
}
