// A function closing a handle clears the place the handle came from: a variable, a static, or a field of this or of a local.
// expect: C function close_obj closes its handle o: pass it from a variable, a static or a field of this or of a local (
// expect: CBindingClose.hx:13)
@:hxmc.handle(0) abstract Obj(hxmc.unsafe.Ptr) {}

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function open_obj():Obj;
	@:hxmc.close(o) static function close_obj(o:Obj):Int;
}

class CBindingClose {
	static function main()
		trace(C.close_obj(C.open_obj()));
}
