// A cycle of phis that is not a boolean: Opt's knownPhiArgs makes an operand
// 1 on the then edge of a branch on it only when the operand is a boolean,
// and a phi of a cycle is assumed one while its other operands are checked.
// `a = c ? a : 5` in the loop makes the loop's phi of a (1, then a) no
// boolean, but the query of the later a found it one under that assumption
// and kept it: the branch on `old` (the loop's phi) then read 5 as 1. The
// ternaries on x1 and x2 are threaded into branches on a and old themselves;
// the tests of i >= n and of c4 make the optimizer look at phis again after
// that.
class BoolPhiCycles {
	@:noinline static function f(n:Int, m1:Int, m2:Int, m3:Int, m4:Int):String {
		var out = "";
		var a = 1;
		var i = 0;
		while (i < n) {
			if (i >= n) out += "?";
			var old = a;
			a = ((m1 >> i) & 1) != 0 ? a : 5;
			var x1 = ((m2 >> i) & 1) != 0 ? a : 0;
			var r1 = x1 != 0 ? a : 9;
			var x2 = ((m3 >> i) & 1) != 0 ? old : 0;
			var r2 = x2 != 0 ? old : 7;
			var c4 = ((m4 >> i) & 1) != 0;
			var y = c4 ? 3 : 0;
			var r3 = y != 0 ? (c4 ? 1 : 2) : 4;
			out += "|" + r1 + "," + r2 + "," + r3;
			i++;
		}
		return out;
	}

	static function main() {
		trace(f(3, 0, 7, 7, 7));
		trace(f(6, 0x2d, 0x3b, 0x2e, 0x13));
	}
}
