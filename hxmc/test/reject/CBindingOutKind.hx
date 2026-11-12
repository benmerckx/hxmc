// An hxmc.Out<T> holds an object or a handle, which C stores by its address.
// expect: C function out_int: hxmc.Out<T> holds a COM interface, an Objective-C or Core Foundation object, or a handle
import hxmc.Out;

@:hxmc.c @:hxmc.fast extern class C {
	static function out_int(o:Out<Int>):Void;
}

class CBindingOutKind {
	static function main()
		C.out_int(new Out<Int>());
}
