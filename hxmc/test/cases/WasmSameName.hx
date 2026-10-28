import hxmc.unsafe.*;

// C functions of the same name in two @:hxmc.lib modules on WebAssembly
// (docs/interop.md, "WebAssembly"): two imports, (a, start) and (b, start),
// each called by its own declarations, each with its own signature; the
// host (WasmSameName.cjs) records which one ran. WebAssembly only.
@:hxmc.c @:hxmc.lib("a") extern class A {
	static function start(x:Int):Void;
	static function tick(x:Int):Int;
}

@:hxmc.c @:hxmc.lib("b") extern class B {
	static function start(x:Int):Void;
	// (another signature than a's tick)
	static function tick(x:Float, y:Int):Float;
}

// a module's name with a dot, and a name with one: (a.b, c) and (a, b.c)
@:hxmc.c @:hxmc.lib("a.b") extern class AB {
	static function c():Int;
}

@:hxmc.lib("a") extern class A2 {
	// (a, start) again: the same import as A.start
	@:hxmc.c("start") static function start2(x:Int):Void;
	@:hxmc.c("b.c") static function bc():Int;
}

// "env", the default module, named or not: one import
@:hxmc.c extern class E {
	static function start(x:Int):Void;
}

@:hxmc.c @:hxmc.lib("env") extern class E2 {
	static function start(x:Int):Void;
}

@:hxmc.c @:hxmc.lib("rec") extern class Rec {
	static function last():Int;
}

class WasmSameName {
	static function main() {
		A.start(1);
		trace(Rec.last());
		B.start(2);
		trace(Rec.last());
		A2.start2(3);
		trace(Rec.last());
		E.start(4);
		trace(Rec.last());
		E2.start(5);
		trace(Rec.last());
		trace(A.tick(41));
		trace(B.tick(2.5, 3));
		trace(AB.c(), A2.bc());
	}
}
