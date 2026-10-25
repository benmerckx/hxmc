package hxmc.scoped;

import hxmc.rt.Abort;

// An element of a Grow by its index (docs/plans/lowlevel.md, "Serialization:
// relative references"): 32 bits, the index + 1 (0: none), so that
// structures of values and Rels in one Grow mean the same wherever their
// bytes are (an Image's). Read with the Grow it points into, `r.get(g)`: a
// Ref, the index checked; a copy of a Rel is as good as the original.
abstract Rel<T>(Int) {
	public static inline function none<T>():Rel<T>
		return cast 0;

	// element i
	public static inline function at<T>(i:Int):Rel<T> {
		if (i < 0) Abort.outOfRange();
		return cast(i + 1);
	}

	public inline function isNone():Bool
		return this == 0;

	// the index (-1: none)
	public inline function index():Int
		return this - 1;

	// g's element (none, out of range: the program ends, Abort)
	public inline function get(g:Grow<T>):Ref<T>
		return g.ref(this - 1);
}
