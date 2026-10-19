package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Stdlib.Atomic. The generated program runs on one thread: plain cells.
class AtomicT<T> {
	public var v:T;
	public function new(v:T) this.v = v;
}

class Atomic {
	public static inline function make<T>(v:T):AtomicT<T> return new AtomicT(v);
	public static inline function makeContended<T>(v:T):AtomicT<T> return new AtomicT(v);
	public static inline function get<T>(a:AtomicT<T>):T return a.v;
	public static inline function set<T>(a:AtomicT<T>, v:T):Unit { a.v = v; return Unit.value; }
	public static inline function exchange<T>(a:AtomicT<T>, v:T):T { var old = a.v; a.v = v; return old; }
	public static function compareAndSet<T>(a:AtomicT<T>, seen:T, v:T):Bool {
		// physical equality, as OCaml's
		if (a.v != seen) return false;
		a.v = v;
		return true;
	}
	public static inline function fetchAndAdd(a:AtomicT<Int63>, n:Int63):Int63 { var old = a.v; a.v = Int63.add(old, n); return old; }
	public static inline function incr(a:AtomicT<Int63>):Unit { a.v = Int63.succ(a.v); return Unit.value; }
	public static inline function decr(a:AtomicT<Int63>):Unit { a.v = Int63.pred(a.v); return Unit.value; }
}
