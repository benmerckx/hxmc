package hxmc;

import hxmc.Mir;
import haxe.Int64;

// Int division and remainder by a constant d without idiv (memory-level Mir,
// after MemLower: Driver; Granlund and Montgomery, "Division by Invariant
// Integers using Multiplication"). With k = floor(log2 |d|): a power of two is
// a shift of n + (2^k - 1 when n < 0); otherwise q = (n * m) >> s, less n >> 31
// (towards zero), with m = 2^s / |d| + 1 (s = 31 + k or 32 + k: m below 2^32)
// multiplied in 64 bits (n sign-extended: the product stays below 2^63), which
// every back end has. A negative divisor negates the quotient; a remainder is
// n - q |d|. MirBuild leaves no divisor 0 or -1 here.
class DivConst {
	public static function run(f:MFunc) {
		var n = 0;
		for (b in f.blocks) {
			var out:Array<MIns> = [];
			for (i in b.ins) {
				var d = i.b >= 0 ? f.vals[i.b] : null;
				if ((i.op == Div || i.op == Rem) && i.ty == I32 && d.op == Const && d.sym == null && d.imm != 0 && d.imm != -1) {
					expand(f, i, d.imm, out);
					n++;
				}
				out.push(i);
			}
			if (n > 0) b.ins = out;
		}
		if (n > 0) f.edited();
	}

	static function expand(f:MFunc, i:MIns, d:Int, out:Array<MIns>) {
		function ins(op:Op, ty:MTy, a:Int, b = -1, imm = 0):Int {
			var x = new MIns(op, ty);
			x.a = a;
			x.b = b;
			x.imm = imm;
			x.pos = i.pos;
			x.block = i.block;
			x.id = f.vals.length;
			f.vals.push(x);
			out.push(x);
			return x.id;
		}
		inline function k(v:Int, ty:MTy = I32):Int
			return ins(Const, ty, -1, -1, v);
		var n = i.a, ad:Int64 = d < 0 ? -Int64.ofInt(d) : Int64.ofInt(d); // (MIN: 2^31)
		var lg = 0;
		while (Int64.shl(1, lg + 1) <= ad)
			lg++;
		var q = n;
		if (lg > 0 && Int64.shl(1, lg) == ad) {
			var sign = lg == 1 ? n : ins(Sar, I32, n, k(lg - 1));
			q = ins(Sar, I32, ins(Add, I32, n, ins(Shr, I32, sign, k(32 - lg))), k(lg));
		} else if (lg > 0) {
			// (s = 31 + k when precise enough, m |d| - 2^s < 2^k: m an immediate)
			var s = 31 + lg, m = Int64.div(Int64.shl(1, s), ad) + 1;
			if (m * ad - Int64.shl(1, s) >= Int64.shl(1, lg))
				m = Int64.div(Int64.shl(1, ++s), ad) + 1;
			var c = ins(Const, I64, -1, -1, m.low);
			f.vals[c].imm2 = m.high;
			var p = ins(Mul, I64, ins(SExt, I64, n), c);
			q = ins(Sub, I32, ins(Trunc, I32, ins(Sar, I64, p, k(s, I64))), ins(Sar, I32, n, k(31)));
		}
		// (q * 2^31 wraps: right for d = MIN)
		var r = i.op == Rem ? ins(Sub, I32, n, ins(Mul, I32, q, k(ad.low))) : d < 0 ? ins(Neg, I32, q) : q;
		i.op = Copy;
		i.a = r;
		i.b = -1;
	}
}
