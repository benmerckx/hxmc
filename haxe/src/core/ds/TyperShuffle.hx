package core.ds;

import haxe.Int64;
import haxe.io.Bytes;

// port: `Random.State.make [|Hashtbl.hash seed|]` and `Random.State.int` of the typer
// shuffle (HAXE_TYPER_SHUFFLE), as OCaml 5's stdlib (random.ml) and runtime
// (caml_lxm_next, the L64X128 generator of LXM) compute them, so a seed gives
// upstream's order
class TyperShuffle {
	static final M = Int64.make(0xd1342543, 0xde82ef95);
	static final MIX = Int64.make(0xdaba0b6e, 0xb09322e3);
	static inline final MAX_INT31 = 0x3FFFFFFF;

	var a:Int64;
	var s:Int64;
	var x0:Int64;
	var x1:Int64;

	public function new(seed:String) {
		// port: Random.State.reinit: the seed array's ints as 64-bit little-endian
		// ... words, MD5 of them with a suffix byte 1 and with 2
		var b = Bytes.alloc(9);
		// port: Hashtbl.hash is non-negative, its upper word 0
		b.setInt32(0, OcamlHash.hashString(seed));
		b.setInt32(4, 0);
		b.set(8, 1);
		var d1 = haxe.crypto.Md5.make(b);
		b.set(8, 2);
		var d2 = haxe.crypto.Md5.make(b);
		a = word(d1, 0) | Int64.ofInt(1);
		s = word(d1, 8);
		var i3 = word(d2, 0);
		var i4 = word(d2, 8);
		x0 = i3 != 0 ? i3 : Int64.ofInt(1);
		x1 = i4 != 0 ? i4 : Int64.ofInt(2);
	}

	static inline function word(b:Bytes, pos:Int):Int64 return Int64.make(b.getInt32(pos + 4), b.getInt32(pos));

	static inline function rotl(x:Int64, k:Int):Int64 return (x << k) | (x >>> (64 - k));

	function next():Int64 {
		var z = s + x0;
		z = (z ^ (z >>> 32)) * MIX;
		z = (z ^ (z >>> 32)) * MIX;
		z = z ^ (z >>> 32);
		s = s * M + a;
		var q0 = x0;
		var q1 = x1;
		q1 ^= q0;
		q0 = rotl(q0, 24);
		q0 = q0 ^ q1 ^ (q1 << 16);
		q1 = rotl(q1, 37);
		x0 = q0;
		x1 = q1;
		return z;
	}

	// 0 <= result < bound (Random.State.int, bound <= 0x3FFFFFFF)
	public function int(bound:Int):Int {
		while (true) {
			var r = next().low & MAX_INT31;
			var v = r % bound;
			if (r - v <= MAX_INT31 - bound + 1) return v;
		}
	}
}
