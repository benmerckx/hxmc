// A handle a function closes has an invalid value, which the place holds after the call.
// expect: C function close_raw: @:hxmc.close names a parameter of a handle type with an invalid value (@:hxmc.handle(-1))
@:hxmc.handle abstract Raw(Int) {}

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function open_raw():Raw;
	@:hxmc.close(r) static function close_raw(r:Raw):Int;
}

class CBindingCloseInvalid {
	static function main() {
		var r = C.open_raw();
		trace(C.close_raw(r));
	}
}
