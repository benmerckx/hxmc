// A handle is made only by a C function (or @:hxmc.unsafe code): a safe kernel cannot cast an Int to one.
// expect: CBindingForge.hx:12: CBindingForge.forge: a cast from Int to the handle Dir (kernel: a handle is made only by a C function or @:hxmc.unsafe code)
@:hxmc.handle(0) abstract Dir(hxmc.unsafe.Ptr) {}

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function opendir_safe(n:Int):Dir;
	static function readdir_safe(d:Dir):Int;
}

class CBindingForge {
	@:hxmc.kernel static function forge(i:Int):Int
		return C.readdir_safe(cast i);

	@:hxmc.kernel static function ok(n:Int):Int
		return C.readdir_safe(C.opendir_safe(n));

	static function main()
		trace(forge(1) + ok(2));
}
