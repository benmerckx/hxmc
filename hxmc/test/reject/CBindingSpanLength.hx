// A C function's span result needs its length: the declaration vouches for it (@:hxmc.len(n)).
// expect: C function nolen: a span result needs its length (@:hxmc.len(n))
import hxmc.Span;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	static function nolen():Span<Int>;
}

class CBindingSpanLength {
	@:hxmc.kernel static function first():Int
		return C.nolen()[0];

	static function main()
		trace(first());
}
