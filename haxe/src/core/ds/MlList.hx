package core.ds;

// port: an immutable OCaml list. Upstream's lists are Arrays in the port; this
// is for the hot places where upstream relies on O(1) `x :: l` and on sharing
// the tail (recursion on the tail, rows built from the rest of a row) and an
// Array would copy at every step: the matcher's rows (typing/matcher). The same
// shape as ml2hx's runtime list (`ml2hx.rt.MlList`), so that the two can become
// one type.
enum MlList<T> {
	Nil;
	Cons(head:T, tail:MlList<T>);
}

// port: the few operations the converted sites use (`using core.ds.MlList.MlListTools`).
class MlListTools {
	public static function hd<T>(l:MlList<T>):T return switch l {
		case Cons(h, _): h;
		case Nil: throw new Failure("hd");
	};

	public static function tl<T>(l:MlList<T>):MlList<T> return switch l {
		case Cons(_, t): t;
		case Nil: throw new Failure("tl");
	};

	/** the list of the array's elements, in its order */
	public static function ofArray<T>(a:Array<T>, ?tail:MlList<T>):MlList<T> {
		var l = tail == null ? Nil : tail;
		var i = a.length;
		while (i > 0) l = Cons(a[--i], l);
		return l;
	}

	public static function toArray<T>(l:MlList<T>):Array<T> {
		var a = [];
		while (true) switch l {
			case Nil: return a;
			case Cons(h, t):
				a.push(h);
				l = t;
		}
	}

	public static function rev<T>(l:MlList<T>):MlList<T> {
		var r = Nil;
		while (true) switch l {
			case Nil: return r;
			case Cons(h, t):
				r = Cons(h, r);
				l = t;
		}
	}

	/** `List.rev_append l1 l2` */
	public static function revAppend<T>(l1:MlList<T>, l2:MlList<T>):MlList<T> {
		while (true) switch l1 {
			case Nil: return l2;
			case Cons(h, t):
				l2 = Cons(h, l2);
				l1 = t;
		}
	}

	/** `l1 @ l2`: copies l1, shares l2 */
	public static function append<T>(l1:MlList<T>, l2:MlList<T>):MlList<T> {
		return switch l2 {
			case Nil: l1;
			case _: revAppend(rev(l1), l2);
		}
	}

	/** `ExtList.List.make n x @ tail` */
	public static function make<T>(n:Int, x:T, ?tail:MlList<T>):MlList<T> {
		var l = tail == null ? Nil : tail;
		for (_ in 0...n) l = Cons(x, l);
		return l;
	}

	public static inline function iterator<T>(l:MlList<T>):MlListIterator<T>
		return new MlListIterator(l);
}

class MlListIterator<T> {
	var l:MlList<T>;

	public inline function new(l:MlList<T>) this.l = l;

	public inline function hasNext():Bool
		return switch l {
			case Nil: false;
			case Cons(_, _): true;
		};

	public inline function next():T
		return switch l {
			case Cons(h, t):
				l = t;
				h;
			case Nil: throw "MlList: next on Nil";
		};
}
