// A String crosses a C call in GC code only: a kernel copies nothing.
// expect: CBindingStringKernel.main: the C function strlen takes or returns a String (kernel: Strings cross C calls in GC code: a kernel copies nothing)
@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	@:native("strlen") static function len(s:String):hxmc.I64;
}

class CBindingStringKernel {
	@:hxmc.kernel static function main()
		C.len("abc");
}
