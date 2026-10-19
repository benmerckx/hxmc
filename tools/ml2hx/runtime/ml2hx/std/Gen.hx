package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// The gen library's generators (gen.ml): 'a Gen.t = unit -> 'a option.
typedef GenT<T> = Unit->MlOption<T>;

class Gen {
	public static inline function next<T>(g:GenT<T>):MlOption<T> return g(Unit.value);
	public static function init<T>(f:Int63->T, ?limit:Int63):GenT<T> {
		var r = 0;
		return function(_:Unit):MlOption<T> {
			if (limit != null && r >= limit.toInt()) return None;
			var x = f(Int63.ofInt(r));
			r++;
			return Some(x);
		};
	}
	public static function map<A, B>(f:A->B, g:GenT<A>):GenT<B> {
		var stop = false;
		return function(_:Unit):MlOption<B> {
			if (stop) return None;
			return switch g(Unit.value) {
				case None: stop = true; None;
				case Some(x): Some(f(x));
			};
		};
	}
}
