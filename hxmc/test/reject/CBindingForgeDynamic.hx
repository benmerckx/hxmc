// Nor from a Dynamic: unboxed where a handle is expected, it would forge one.
// expect: CBindingForgeDynamic.hx:11: CBindingForgeDynamic.unbox: a value of type Dynamic as the handle Dir (kernel: a handle is made only by a C function or @:hxmc.unsafe code)
@:hxmc.handle(0) abstract Dir(hxmc.unsafe.Ptr) {}

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function readdir_safe(d:Dir):Int;
}

class CBindingForgeDynamic {
	@:hxmc.kernel static function unbox(d:Dynamic):Int {
		var h:Dir = d;
		return C.readdir_safe(h);
	}

	static function main()
		trace(unbox(null));
}
