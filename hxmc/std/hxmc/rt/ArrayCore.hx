package hxmc.rt;

import hxmc.I64;
import hxmc.rt.ArrayView;
import hxmc.rt.ArrayView.RefKey;

// Array's searches and its reversal, written once as scoped code over an
// ArrayView (docs/plans/lowlevel.md, "GC references in the core"): scalar
// elements found by value, references by identity (the face, hxmc.rt.Arr,
// says when identity is the equality: Repr.identityEq of the needle), the
// elements moved in place (a reference array's barrier the face's, after).
// Each search gives the first index in [from, end) (or the last in [0, from],
// lastIndex*) holding the needle; -1: none. The face clamps from and end.
@:hxmc.scoped
class ArrayCore {
	public static inline function indexInt(v:ArrayView, x:Int, from:Int):Int {
		var r = -1;
		for (i in from...v.length)
			if (v.int(i) == x) {
				r = i;
				break;
			}
		return r;
	}

	public static inline function indexFloat(v:ArrayView, x:Float, from:Int):Int {
		var r = -1;
		for (i in from...v.length)
			if (v.float(i) == x) {
				r = i;
				break;
			}
		return r;
	}

	public static inline function indexBool(v:ArrayView, x:Int, from:Int):Int {
		var r = -1;
		for (i in from...v.length)
			if (v.bool(i) == x) {
				r = i;
				break;
			}
		return r;
	}

	public static inline function indexRef(v:ArrayView, k:RefKey, from:Int):Int {
		var r = -1;
		for (i in from...v.length)
			if (v.isRef(i, k)) {
				r = i;
				break;
			}
		return r;
	}

	// (the I64 kind compared as Floats, as Haxe's == of an Int64 element and a Float)
	public static inline function lastIndexNum(v:ArrayView, kind:Int, x:Float, from:Int):Int {
		var r = -1, i = from;
		while (i >= 0) {
			var e:Float = kind == Repr.AK_I32 ? (v.int(i) : Float) : kind == Repr.AK_F64 ? v.float(i) : {
				var l:Float = cast v.long(i);
				l;
			};
			if (e == x) {
				r = i;
				break;
			}
			i--;
		}
		return r;
	}

	public static inline function lastIndexBool(v:ArrayView, x:Int, from:Int):Int {
		var r = -1, i = from;
		while (i >= 0) {
			if (v.bool(i) == x) {
				r = i;
				break;
			}
			i--;
		}
		return r;
	}

	public static inline function lastIndexRef(v:ArrayView, k:RefKey, from:Int):Int {
		var r = -1, i = from;
		while (i >= 0) {
			if (v.isRef(i, k)) {
				r = i;
				break;
			}
			i--;
		}
		return r;
	}

	// the elements (of es bytes linearly) in reverse order
	public static inline function reverse(v:ArrayView, es:Int) {
		var i = 0, j = v.length - 1;
		// (a loop per size: the swap's test folded away)
		if (es == 1)
			while (i < j)
				v.swap(i++, j--, 1)
		else if (es == 4)
			while (i < j)
				v.swap(i++, j--, 4)
		else
			while (i < j)
				v.swap(i++, j--, 8);
	}
}
