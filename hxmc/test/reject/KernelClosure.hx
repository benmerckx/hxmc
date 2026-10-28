// No closure in kernels: making one allocates.
// expect: KernelClosure.hx:7: KernelClosure.make: the local g is a function (kernel: no closures)
class KernelClosure {
	@:hxmc.kernel static function make(v:Int):Int {
		var x = v + 1;
		var y = x * 2;
		var g = function(z:Int) return z + v;
		return y;
	}

	static function main()
		trace(make(2));
}
