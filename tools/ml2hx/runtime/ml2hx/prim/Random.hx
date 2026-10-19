package ml2hx.prim;

import haxe.Int64;
import ml2hx.rt.*;

// OCaml's lxm.c: the LXM generator over a state of four int64 (a bigarray:
// a, s, x0, x1).
class Random {
	static final M = Int64.make(0xdaba0b6e, 0xb09322e3);
	static final LCG = Int64.make(0xd1342543, 0xde82ef95);
	static inline function rotl(x:Int64, k:Int):Int64 return (x << k) | (x >>> (64 - k));

	public static function camlLxmNext<B, C>(st:BigarrayData.Bigarray<Int64, B, C>):Int64 {
		var d = st.data, o = st.offset;
		var a:Int64 = d[o], s:Int64 = d[o + 1], x0:Int64 = d[o + 2], x1:Int64 = d[o + 3];
		var z = s + x0;
		z = (z ^ (z >>> 32)) * M;
		z = (z ^ (z >>> 32)) * M;
		z = z ^ (z >>> 32);
		d[o + 1] = s * LCG + a;
		var q0 = x0, q1 = x1;
		q1 = q1 ^ q0;
		q0 = rotl(q0, 24);
		q0 = q0 ^ q1 ^ (q1 << 16);
		q1 = rotl(q1, 37);
		d[o + 2] = q0;
		d[o + 3] = q1;
		return z;
	}
}
