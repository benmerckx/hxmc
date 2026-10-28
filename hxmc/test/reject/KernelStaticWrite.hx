// A kernel reads statics but does not write them (two jobs writing one), also a struct static's field.
// expect: KernelStaticWrite.hx:15: KernelStaticWrite.count: a write of the static calls (kernel: statics are read-only in kernels)
// expect: KernelStaticWrite.hx:16: KernelStaticWrite.count: a write of the static last (kernel: statics are read-only in kernels)
@:hxmc.struct @:publicFields class Pair {
	var a:Int;
	var b:Int;
}

class KernelStaticWrite {
	static var calls = 0;
	static var last:Pair;
	static final LIMIT = 10;

	@:hxmc.kernel static function count(v:Int):Int {
		calls++;
		last.a = v;
		return v < LIMIT ? v : LIMIT;
	}

	static function main()
		trace(count(3));
}
