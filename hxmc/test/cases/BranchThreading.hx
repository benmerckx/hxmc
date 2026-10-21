// Conditions whose && and || chains the optimizer threads (Opt.simplifyCfg,
// Opt.condProp: a branch on a value known from the branch that leads to it) and
// whose bit tests become TESTI (x64 Isel): chains of flag tests, values of
// such chains used as data too, a branch on a value tested again, masks of
// Int64 values (imm32 sign-extended, and masks too wide for one).
import haxe.Int64;

class Flags {
	public var a:Int;
	public var b:Int;
	public var w:Int64;

	public function new(a, b, w) {
		this.a = a;
		this.b = b;
		this.w = w;
	}
}

class BranchThreading {
	static var wild:Flags = new Flags(-1, -1, -1);

	static function chainAnd(f:Flags):Bool
		return f.a & 1 != 0 && f.a & 4 != 0 && f.b & 1 != 0 && f.b & 4 == 0;

	static function chainOr(f:Flags, g:Flags):Bool {
		if (f.b & 1 != 0 || f.a & 0x40000 != 0 || f == g) return true;
		if (f.b & 2 != 0) return false;
		return f.a > 3;
	}

	static function mixed(f:Flags):Int {
		// a chain's value kept and branched on again
		var x = f.a & 2 != 0 && (f.b & 8 != 0 || f.a & 16 == 0);
		var n = 0;
		if (x) n += 1;
		if (x && f.b & 32 != 0) n += 2;
		if (!x || f.a & 0x80000000 != 0) n += 4;
		return n + (x ? 8 : 0);
	}

	static function wide(f:Flags):Int {
		var n = 0;
		if (f.w & Int64.make(0, 0x10) != 0) n |= 1;
		if (f.w & Int64.make(-1, -8) == 0) n |= 2; // -8: an imm32, sign-extended
		if (f.w & Int64.make(0x100, 0) != 0) n |= 4; // 1 << 40: not an imm32
		if (f.w & Int64.make(0, 0x80000000) != 0) n |= 8; // 2^31: not an imm32 for 64 bits
		return n;
	}

	static function same(v:Int):Int {
		var c = v & 3;
		var n = 0;
		if (c != 0) {
			if (c != 0) n += 1 else n += 100; // known
			if (v & 1 != 0 || c == 2) n += 2;
		} else {
			if (c == 0) n += 10;
		}
		return n;
	}

	static function main() {
		var s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0;
		for (i in 0...512) {
			var f = new Flags(i * 7 ^ (i << 18), i * 13 + (i >> 2), Int64.make(i * 3, i * 0x01010101 - 9));
			if (chainAnd(f)) s1++;
			if (chainOr(f, i % 50 == 0 ? f : wild)) s2 += i;
			s3 += mixed(f);
			s4 = s4 * 31 + wide(f);
			s5 += same(i);
		}
		trace(s1, s2, s3, s4, s5);
		trace(chainOr(wild, wild), mixed(wild), wide(wild), wide(new Flags(0, 0, 0)));
	}
}
