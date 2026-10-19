package ml2hx.std;

import Array;
import ml2hx.rt.*;

// Stdlib.Seq: 'a t = unit -> 'a node
typedef SeqT<A> = Unit->SeqNode<A>;

enum SeqNode<A> {
	Nil;
	Cons(v:A, next:SeqT<A>);
}

class Seq {
	public static function empty<A>():SeqT<A>
		return _ -> Nil;

	public static function returnValue<A>(x:A):SeqT<A>
		return _ -> Cons(x, empty());

	public static function cons<A>(x:A, next:SeqT<A>):SeqT<A>
		return _ -> Cons(x, next);

	public static function isEmpty<A>(s:SeqT<A>):Bool
		return switch s(Unit.value) { case Nil: true; case _: false; };

	public static function iter<A>(f:A->Unit, s:SeqT<A>):Unit {
		while (true) switch s(Unit.value) {
			case Nil: return Unit.value;
			case Cons(x, next): f(x); s = next;
		}
	}

	public static function foldLeft<A, B>(f:(A, B) -> A, acc:A, s:SeqT<B>):A {
		while (true) switch s(Unit.value) {
			case Nil: return acc;
			case Cons(x, next): acc = f(acc, x); s = next;
		}
	}

	public static function map<A, B>(f:A->B, s:SeqT<A>):SeqT<B>
		return _ -> switch s(Unit.value) {
			case Nil: Nil;
			case Cons(x, next): Cons(f(x), map(f, next));
		}

	public static function filter<A>(p:A->Bool, s:SeqT<A>):SeqT<A>
		return _ -> {
			var r:SeqNode<A> = Nil;
			while (true) switch s(Unit.value) {
				case Nil: r = Nil; break;
				case Cons(x, next):
					if (p(x)) {
						r = Cons(x, filter(p, next));
						break;
					}
					s = next;
			}
			r;
		}

	public static function append<A>(a:SeqT<A>, b:SeqT<A>):SeqT<A>
		return _ -> switch a(Unit.value) {
			case Nil: b(Unit.value);
			case Cons(x, next): Cons(x, append(next, b));
		}

	public static function length<A>(s:SeqT<A>):Int63 {
		var n = 0;
		while (true) switch s(Unit.value) {
			case Nil: return Int63.ofInt(n);
			case Cons(_, next): n++; s = next;
		}
	}
}
