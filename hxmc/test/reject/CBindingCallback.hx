// A typed callback is a static @:hxmc.callback function named as the argument: no closure (C keeps no GC reference).
// expect: C function apply takes a callback: pass a static function declared @:hxmc.callback, by name (
// expect: CBindingCallback.hx:11)
@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function apply(f:Int->Int, v:Int):Int;
}

class CBindingCallback {
	static function main() {
		var k = 2;
		trace(C.apply(v -> v * k, 1));
	}
}
