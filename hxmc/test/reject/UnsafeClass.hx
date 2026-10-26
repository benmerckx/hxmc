// @:hxmc.unsafe on a class covers its functions; throwing, closures and dynamic calls are GC points.
// expect: UnsafeClass.thrower is declared @:hxmc.unsafe but reaches a GC point: it throws
// expect: UnsafeClass.closure is declared @:hxmc.unsafe but reaches a GC point: it allocates a closure
// expect: UnsafeClass.dyncall is declared @:hxmc.unsafe but reaches a GC point: it calls through a closure or structural field
@:hxmc.unsafe class UnsafeClass {
	static function thrower(n:Int):Int {
		if (n < 0) throw "negative";
		return n;
	}

	static function closure(n:Int):Void->Int
		return () -> n;

	static function dyncall(f:Int->Int):Int
		return f(1);

	static function ok(n:Int):Int
		return n * 2;

	static function main() {
		trace(thrower(1) + closure(2)() + dyncall(x -> x) + ok(3));
	}
}
