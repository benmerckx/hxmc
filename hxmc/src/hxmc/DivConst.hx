package hxmc;

import hxmc.Mir;
import haxe.Int64;

// Division and remainder by a constant without a divide instruction
// (memory-level Mir, after MemLower and Fold: Driver): a multiplication by
// the divisor's reciprocal scaled by a power of two, whose high bits are the
// quotient (Granlund and Montgomery, "Division by Invariant Integers using
// Multiplication", 1994; the magic numbers computed as libdivide does), a
// power of two shifts and masks (signed: the dividend rounded towards zero
// first; one known not to be negative needs nothing), a remainder the
// dividend less the quotient times the divisor. Signed divisions of 32 bits
// multiply in 64 (the I32 dividend sign-extended, the 33-bit factor an I64
// constant: the product stays below 2^63), which every back end has; those
// of 64 bits take the high half of a 128-bit product (MulHi, UMulHi: x86-64
// and arm64 only, `wide`). A remainder and a quotient of the same dividend
// and divisor in a block share the quotient. Div and Rem by 0 or -1 are not
// expanded (MirBuild guards them; a Div by -1 left here is Neg's).
class DivConst {
	public static var on = Sys.getEnv("HXMC_DIVCONST") != "0";

	var f:MFunc;
	var wide:Bool;
	var at:MIns; // the instruction expanded (it becomes the last of its expansion)
	var before:Array<MIns>; // the instructions before it
	var quots:Map<String, Int>; // in the block: the quotient by |d| of a dividend (its key)

	public var expanded = 0;

	public function new(f:MFunc, wide:Bool) {
		this.f = f;
		this.wide = wide;
	}

	public function run() {
		for (b in f.blocks) {
			var out:Null<Array<MIns>> = null;
			quots = null;
			for (k in 0...b.ins.length) {
				var i = b.ins[k];
				if (!i.dead && (i.op == Div || i.op == Rem || i.op == UDiv || i.op == URem) && (i.ty == I32 || i.ty == I64)) {
					var d = f.vals[i.b];
					if (d.op == Const && d.sym == null) {
						at = i;
						before = [];
						if (expand(i, i.ty == I32 ? Int64.ofInt(d.imm) : Int64.make(d.imm2, d.imm))) {
							if (out == null) out = b.ins.slice(0, k);
							for (x in before)
								out.push(x);
							expanded++;
						}
					}
				}
				if (out != null) out.push(i);
			}
			if (out != null) b.ins = out;
		}
		if (expanded > 0) f.edited();
	}

	// ---- writing the expansion

	function ins(op:Op, ty:MTy, a:Int, b:Int):Int {
		var i = new MIns(op, ty);
		i.a = a;
		i.b = b;
		i.pos = at.pos;
		i.id = f.vals.length;
		i.block = at.block;
		f.vals.push(i);
		before.push(i);
		return i.id;
	}

	function const(ty:MTy, v:Int64):Int {
		var i = new MIns(Const, ty);
		i.imm = v.low;
		i.imm2 = ty == I64 ? v.high : 0;
		i.pos = at.pos;
		i.id = f.vals.length;
		i.block = at.block;
		f.vals.push(i);
		before.push(i);
		return i.id;
	}

	inline function k(ty:MTy, v:Int):Int
		return const(ty, Int64.ofInt(v));

	// the instruction expanded becomes op a b (its value number stays)
	function finish(op:Op, a:Int, b:Int):Bool {
		at.op = op;
		at.a = a;
		at.b = b;
		at.c = -1;
		return true;
	}

	// the instruction becomes a copy of v
	inline function result(v:Int):Bool
		return finish(Copy, v, -1);

	// ---- the expansions

	function expand(i:MIns, d:Int64):Bool {
		var ty = i.ty, w = ty == I32 ? 32 : 64;
		var n = i.a;
		var signed = i.op == Div || i.op == Rem, rem = i.op == Rem || i.op == URem;
		if (signed) {
			if (d == 0 || d == -1) return false;
			var neg = d < 0;
			var ad = neg ? -d : d; // (MIN: 2^(w-1), unsigned)
			var lg = pow2(ad);
			if (ad == 1) return rem ? result(k(ty, 0)) : neg ? finish(Neg, n, -1) : result(n);
			if (lg > 0) {
				if (nonNegative(n)) {
					// a shift, a mask
					if (rem) return finish(And, n, const(ty, ad - 1));
					return neg ? finish(Neg, ins(Sar, ty, n, k(ty, lg)), -1) : finish(Sar, n, k(ty, lg));
				}
				// n rounded towards zero: n + (2^lg - 1 when n < 0)
				var sign = lg == 1 ? n : ins(Sar, ty, n, k(ty, lg - 1));
				var t = ins(Add, ty, n, ins(Shr, ty, sign, k(ty, w - lg)));
				if (rem) return finish(Sub, n, ins(And, ty, t, const(ty, -ad)));
				return neg ? finish(Neg, ins(Sar, ty, t, k(ty, lg)), -1) : finish(Sar, t, k(ty, lg));
			}
			if (ty == I64 && !wide) return false;
			var q = quotient(n, ad, ty, true);
			if (rem) return finish(Sub, n, ins(Mul, ty, q, const(ty, ad)));
			return neg ? finish(Neg, q, -1) : result(q);
		}
		// unsigned (64 bits: Mem.udiv)
		if (ty != I64 || d == 0) return false;
		if (d == 1) return rem ? result(k(ty, 0)) : result(n);
		var lg = pow2(d);
		if (lg > 0) return rem ? finish(And, n, const(ty, d - 1)) : finish(Shr, n, k(ty, lg));
		// (2^63 and more: one comparison; rare, left to the instruction)
		if (d < 0 || !wide) return false;
		var q = quotient(n, d, ty, false);
		if (rem) return finish(Sub, n, ins(Mul, ty, q, const(ty, d)));
		return result(q);
	}

	// the quotient of n by d (not a power of two, 2 < d < 2^(w-1), or
	// unsigned up to 2^63), shared in the block
	function quotient(n:Int, d:Int64, ty:MTy, signed:Bool):Int {
		var key = n + (signed ? "s" : "u") + d.high + ":" + d.low;
		if (quots == null) quots = new Map();
		var q = quots.get(key);
		if (q != null) return q;
		var w = ty == I32 ? 32 : 64;
		if (signed) {
			var m = magicSigned(w, d);
			if (ty == I32) {
				// (n * m) >> (32 + shift), m below 2^32 (with the add form's
				// n folded in: m - 2^32 + 2^32), less -1 when n < 0
				var p = ins(Mul, I64, ins(SExt, I64, n, -1), const(I64, m.m));
				var q0 = ins(Trunc, I32, ins(Sar, I64, p, k(I64, 32 + m.shift)), -1);
				q = ins(Sub, I32, q0, ins(Sar, I32, n, k(I32, 31)));
			} else {
				var hi = ins(MulHi, I64, n, const(I64, m.m));
				if (m.add) hi = ins(Add, I64, hi, n);
				if (m.shift > 0) hi = ins(Sar, I64, hi, k(I64, m.shift));
				q = ins(Sub, I64, hi, ins(Sar, I64, n, k(I64, 63)));
			}
		} else {
			var m = magicUnsigned(d);
			var t = ins(UMulHi, I64, n, const(I64, m.m));
			if (m.add) t = ins(Add, I64, ins(Shr, I64, ins(Sub, I64, n, t), k(I64, 1)), t);
			q = m.shift > 0 ? ins(Shr, I64, t, k(I64, m.shift)) : t;
		}
		quots.set(key, q);
		return q;
	}

	// whether v is known not to be negative (as a signed value of its type)
	function nonNegative(v:Int):Bool {
		var x = f.vals[v];
		inline function plainNonNeg(c:Int):Bool {
			var y = f.vals[c];
			return y.op == Const && y.sym == null && (y.ty == I32 ? y.imm >= 0 : y.imm2 >= 0);
		}
		return switch x.op {
			case Const: x.sym == null && plainNonNeg(v);
			case And: plainNonNeg(x.a) || plainNonNeg(x.b);
			case Shr: f.vals[x.b].op == Const && f.vals[x.b].sym == null && (f.vals[x.b].imm & (x.ty == I32 ? 31 : 63)) != 0;
			case ZExt: true;
			case Load: !x.signed && x.size < (x.ty == I32 ? 4 : 8);
			case _: false;
		}
	}

	// ---- the magic numbers

	// log2 of d (unsigned) when it is a power of two (> 1), else 0
	static function pow2(d:Int64):Int {
		if (d == 0 || (d & (d - 1)) != 0) return 0;
		var n = 0;
		while (d != 1) {
			d = d >>> 1;
			n++;
		}
		return n;
	}

	// floor(log2 d), d unsigned and not 0
	static function log2(d:Int64):Int {
		var n = -1;
		while (d != 0) {
			d = d >>> 1;
			n++;
		}
		return n;
	}

	static inline function ult(a:Int64, b:Int64):Bool
		return Int64.ucompare(a, b) < 0;

	// 2^e / d, unsigned (d not 0; the quotient's low 64 bits), and its remainder
	static function pow2Div(e:Int, d:Int64):{q:Int64, r:Int64} {
		var q:Int64 = 0, r:Int64 = 0;
		var bit = e;
		while (bit >= 0) {
			var carry = r < 0; // (the shift below overflows: r * 2 >= 2^64 > d)
			r = (r << 1) | (bit == e ? 1 : 0);
			q = q << 1;
			if (carry || !ult(r, d)) {
				r = r - d;
				q = q | 1;
			}
			bit--;
		}
		return {q: q, r: r};
	}

	// signed division by d (2 < d < 2^(w-1), not a power of two): the factor
	// m (unsigned, w bits), whether the dividend is added to the high half
	// (m >= 2^(w-1): m - 2^w as signed), the shift after
	public static function magicSigned(w:Int, d:Int64):{m:Int64, add:Bool, shift:Int} {
		var fl = log2(d);
		var pr = pow2Div(w + fl - 1, d);
		var pm = pr.q, rem = pr.r;
		var e = d - rem;
		if (ult(e, Int64.shl(1, fl))) return {m: mask(w, pm + 1), add: false, shift: fl - 1};
		pm = pm + pm;
		var twice = rem + rem;
		if (!ult(twice, d) || ult(twice, rem)) pm = pm + 1;
		return {m: mask(w, pm + 1), add: true, shift: fl};
	}

	// unsigned division by d (64 bits, 2 < d < 2^63, not a power of two):
	// t the high half of n * m; the quotient t >> shift, or with add
	// ((n - t) >> 1 + t) >> shift (m: the low 64 bits of a 65-bit factor)
	public static function magicUnsigned(d:Int64):{m:Int64, add:Bool, shift:Int} {
		var fl = log2(d);
		var pr = pow2Div(64 + fl, d);
		var pm = pr.q, rem = pr.r;
		var e = d - rem;
		if (ult(e, Int64.shl(1, fl))) return {m: pm + 1, add: false, shift: fl};
		pm = pm + pm;
		var twice = rem + rem;
		if (!ult(twice, d) || ult(twice, rem)) pm = pm + 1;
		return {m: pm + 1, add: true, shift: fl};
	}

	static inline function mask(w:Int, v:Int64):Int64
		return w == 32 ? Int64.make(0, v.low) : v;
}
