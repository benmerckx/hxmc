package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import haxe.Int64 as I64;
import ml2hx.rt.*;

// Stdlib.Random.State: OCaml 5's LXM generator (runtime/lxm.c, random.ml).
class RandomStateT {
	public var a:I64;
	public var s:I64;
	public var x0:I64;
	public var x1:I64;
	public function new(a:I64, s:I64, x0:I64, x1:I64) {
		this.a = I64.or(a, I64.ofInt(1));
		this.s = s;
		this.x0 = I64.isZero(x0) ? I64.ofInt(1) : x0;
		this.x1 = I64.isZero(x1) ? I64.ofInt(2) : x1;
	}
}

class Random_State {
	static final M = I64.make(0xdaba0b6e, 0xb09322e3);
	static final LCG = I64.make(0xd1342543, 0xde82ef95);
	static inline function rotl(x:I64, k:Int):I64 return I64.or(I64.shl(x, k), I64.ushr(x, 64 - k));
	public static function next(st:RandomStateT):I64 {
		var z = I64.add(st.s, st.x0);
		z = I64.mul(I64.xor(z, I64.ushr(z, 32)), M);
		z = I64.mul(I64.xor(z, I64.ushr(z, 32)), M);
		z = I64.xor(z, I64.ushr(z, 32));
		st.s = I64.add(I64.mul(st.s, LCG), st.a);
		var q0 = st.x0, q1 = st.x1;
		q1 = I64.xor(q1, q0);
		q0 = rotl(q0, 24);
		q0 = I64.xor(I64.xor(q0, q1), I64.shl(q1, 16));
		q1 = rotl(q1, 37);
		st.x0 = q0;
		st.x1 = q1;
		return z;
	}
	static function le64(s:String, o:Int):I64 {
		var lo = 0, hi = 0;
		for (i in 0...4) lo |= StringTools.fastCodeAt(s, o + i) << (8 * i);
		for (i in 0...4) hi |= StringTools.fastCodeAt(s, o + 4 + i) << (8 * i);
		return I64.make(hi, lo);
	}
	public static function make(seed:HArray<Int63>):RandomStateT {
		var b = new StringBuf();
		for (v in seed) {
			var x = v.toInt64();
			for (i in 0...4) b.addChar((x.low >>> (8 * i)) & 255);
			for (i in 0...4) b.addChar((x.high >>> (8 * i)) & 255);
		}
		var base = b.toString();
		var d1 = Digest.string(base + "\x01"), d2 = Digest.string(base + "\x02");
		return new RandomStateT(le64(d1, 0), le64(d1, 8), le64(d2, 0), le64(d2, 8));
	}
	public static function makeSelfInit(_:Unit):RandomStateT return make([Int63.ofFloat(Date.now().getTime()), Int63.ofFloat(Math.random() * 1073741823)]);
	public static function copy(s:RandomStateT):RandomStateT {
		var c = new RandomStateT(s.a, s.s, s.x0, s.x1);
		return c;
	}
	public static function bits(s:RandomStateT):Int63 return Int63.ofInt(next(s).low & 0x3FFFFFFF);
	static function intAux(s:RandomStateT, n:Int63, mask:Int63):Int63 {
		while (true) {
			var r = Int63.logand(Int63.ofInt64(next(s)), mask);
			var v = Int63.mod(r, n);
			if (!Int63.gt(Int63.sub(r, v), Int63.add(Int63.sub(mask, n), Int63.one))) return v;
		}
	}
	public static function int(s:RandomStateT, bound:Int63):Int63 {
		if (Int63.gt(bound, Int63.ofInt(0x3FFFFFFF)) || Int63.le(bound, Int63.zero)) throw new InvalidArgument("Random.int");
		return intAux(s, bound, Int63.ofInt(0x3FFFFFFF));
	}
	public static function fullInt(s:RandomStateT, bound:Int63):Int63 {
		if (Int63.le(bound, Int63.zero)) throw new InvalidArgument("Random.full_int");
		var mask = Int63.le(bound, Int63.ofInt(0x3FFFFFFF)) ? Int63.ofInt(0x3FFFFFFF) : Int63.le(bound, Int63.ofInt(0x7FFFFFFF)) ? Int63.ofInt(0x7FFFFFFF) : Int63.maxInt;
		return intAux(s, bound, mask);
	}
	public static function int64(s:RandomStateT, bound:I64):I64 {
		if (I64.compare(bound, I64.ofInt(0)) <= 0) throw new InvalidArgument("Random.int64");
		while (true) {
			var r = I64.ushr(next(s), 1);
			var v = I64.mod(r, bound);
			if (I64.compare(I64.sub(r, v), I64.add(I64.sub(Int64.maxInt, bound), I64.ofInt(1))) <= 0) return v;
		}
	}
	static function rawfloat(s:RandomStateT):Float {
		while (true) {
			var n = I64.ushr(next(s), 11);
			if (!I64.isZero(n)) return Float64.ofInt64(n) * 1.1102230246251565e-16;
		}
	}
	public static function float(s:RandomStateT, bound:Float):Float return rawfloat(s) * bound;
	public static function bool(s:RandomStateT):Bool return I64.compare(next(s), I64.ofInt(0)) < 0;
	public static function bits32(s:RandomStateT):haxe.Int32 return next(s).low;
	public static function bits64(s:RandomStateT):I64 return next(s);
	public static function split(s:RandomStateT):RandomStateT {
		var i1 = next(s), i2 = next(s), i3 = next(s), i4 = next(s);
		return new RandomStateT(i1, i2, i3, i4);
	}
}
