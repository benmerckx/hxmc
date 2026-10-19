package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Stdlib.Lazy over ml2hx.rt.Lazy.
class Lazy {
	public static inline function force<T>(l:ml2hx.rt.Lazy<T>):T return l.force();
	public static inline function forceVal<T>(l:ml2hx.rt.Lazy<T>):T return l.force();
	public static inline function fromVal<T>(v:T):ml2hx.rt.Lazy<T> return ml2hx.rt.Lazy.fromVal(v);
	public static inline function fromFun<T>(f:Unit->T):ml2hx.rt.Lazy<T> return new ml2hx.rt.Lazy(() -> f(Unit.value));
	public static inline function isVal<T>(l:ml2hx.rt.Lazy<T>):Bool return l.isVal();
	public static function map<A, B>(f:A->B, l:ml2hx.rt.Lazy<A>):ml2hx.rt.Lazy<B> return new ml2hx.rt.Lazy(() -> f(l.force()));
}
