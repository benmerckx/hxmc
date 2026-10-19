package ml2hx.prim;

import ml2hx.rt.*;

// OCaml's hash.c (Poly holds the port of its traversal and mixing).
class Hash {
	public static function camlHash<T>(count:Int63, limit:Int63, seed:Int63, v:T):Int63
		return Int63.ofInt(Poly.hashParam(count.toInt(), limit.toInt(), seed.toInt(), v));
}
