// A lent GC value is opaque: a kernel reads it through its view, never by a field.
// expect: KernelLoanField.hx:5: KernelLoanField.f: the field length of the GC value String (kernel: a kernel reads a GC value through its view)
class KernelLoanField {
	@:hxmc.kernel static function f(s:String):Int
		return s.length;

	static function main()
		trace(f("x"));
}
