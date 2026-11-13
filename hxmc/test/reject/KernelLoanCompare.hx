// Comparing GC values is an operation on them: only a comparison with null is not.
// expect: KernelLoanCompare.hx:5: KernelLoanCompare.f: an operation on of the GC value String (kernel: a kernel reads a GC value through its view)
class KernelLoanCompare {
	@:hxmc.kernel static function f(a:String, b:String):Bool
		return a == b;

	static function main()
		trace(f("x", "y"));
}
