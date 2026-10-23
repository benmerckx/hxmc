import hxmc.a64.Asm;

// Table-driven test of the AArch64 encoder (hxmc/tools/enctest.py --arch a64).
class EncTestA64 {
	static var out = new StringBuf();

	static function emit(text:String, f:Asm->Void) {
		var a = new Asm();
		f(a);
		var hex = new StringBuf();
		for (i in 0...a.b.len)
			hex.add(StringTools.hex(a.b.get8(i), 2));
		out.add(text + "|" + hex.toString().toLowerCase() + "\n");
	}

	static function r(n:Int, x:Bool)
		return Asm.regName(n, x);

	static function z(n:Int, x:Bool)
		return Asm.zrName(n, x);

	static function main() {
		var regs = [0, 1, 7, 15, 19, 28, 29, 30];
		for (x in [false, true]) {
			for (d in regs)
				for (n in [0, 9, 30])
					for (m in [3, 17]) {
						emit('add ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.addSubR(0, x, d, n, m));
						emit('subs ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.addSubR(3, x, d, n, m));
						emit('sub ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.addSubR(2, x, d, n, m));
						emit('and ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.logicR(0, x, d, n, m));
						emit('orr ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.logicR(1, x, d, n, m));
						emit('eor ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.logicR(2, x, d, n, m));
						emit('mul ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.mul(x, d, n, m));
						emit('sdiv ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.dp2(1, x, d, n, m));
						emit('lsl ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.dp2(2, x, d, n, m));
						emit('lsr ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.dp2(3, x, d, n, m));
						emit('asr ${r(d, x)}, ${r(n, x)}, ${r(m, x)}', a -> a.dp2(4, x, d, n, m));
						emit('msub ${r(d, x)}, ${r(n, x)}, ${r(m, x)}, ${r(5, x)}', a -> a.msub(x, d, n, m, 5));
						emit('csel ${r(d, x)}, ${r(n, x)}, ${r(m, x)}, lt', a -> a.csel(x, d, n, m, Asm.LT));
					}
			for (d in regs) {
				for (imm in [0, 1, 4095])
					emit('add ${r(d, x)}, ${r(d == 30 ? 31 : d, x)}, #$imm', a -> a.addSubI(0, x, d, d == 30 ? 31 : d, imm));
				emit('sub ${r(d, x)}, ${r(3, x)}, #1, lsl #12', a -> a.addSubI(2, x, d, 3, 1, true));
				emit('cmp ${r(d, x)}, #42', a -> a.cmpI(x, d, 42));
				emit('cmp ${r(d, x)}, ${r(4, x)}', a -> a.cmpR(x, d, 4));
				emit('neg ${r(d, x)}, ${r(6, x)}', a -> a.neg(x, d, 6));
				emit('mvn ${r(d, x)}, ${r(6, x)}', a -> a.mvn(x, d, 6));
				emit('cset ${r(d, x)}, eq', a -> a.cset(x, d, Asm.EQ));
				emit('cset ${r(d, x)}, hi', a -> a.cset(x, d, Asm.HI));
				emit('lsl ${r(d, x)}, ${r(2, x)}, #3', a -> a.lslI(x, d, 2, 3));
				emit('lsr ${r(d, x)}, ${r(2, x)}, #7', a -> a.lsrI(x, d, 2, 7));
				emit('asr ${r(d, x)}, ${r(2, x)}, #1', a -> a.asrI(x, d, 2, 1));
				emit('mov ${r(d, x)}, ${r(12, x)}', a -> a.movR(x, d, 12));
				emit('movz ${r(d, x)}, #4660, lsl #16', a -> a.movz(x, d, 0x1234, 1));
				emit('movk ${r(d, x)}, #65535', a -> a.movk(x, d, 0xffff, 0));
				emit('tst ${r(d, x)}, ${r(8, x)}', a -> a.tstR(x, d, 8));
				emit('scvtf d${d}, ${r(d, x)}', a -> a.scvtf(x, 32 + d, d));
				emit('fcvtzs ${r(d, x)}, d${d}', a -> a.fcvtzs(x, d, 32 + d));
			}
			// logical immediates
			var imms:Array<Array<Int>> = [[1, 0], [0xff, 0], [0xff00, 0], [0x0f0f0f0f, 0x0f0f0f0f], [0x55555555, 0x55555555], [-2, -1], [0x7fffffff, 0],
				[0xfffffff0, 0], [0x00ff00ff, 0x00ff00ff], [0x80000000, 0]];
			for (v in imms) {
				var lo = v[0], hi = x ? v[1] : 0;
				if (!x && Asm.bitmask(lo, lo, false) < 0) continue;
				if (x && Asm.bitmask(lo, hi, true) < 0) continue;
				var hex = x ? '0x${StringTools.hex(hi, 8)}${StringTools.hex(lo, 8)}' : '0x${StringTools.hex(lo, 8)}';
				emit('and ${r(3, x)}, ${r(4, x)}, #$hex', a -> a.logicI(0, x, 3, 4, lo, hi));
				emit('orr ${r(3, x)}, ${z(31, x)}, #$hex', a -> a.logicI(1, x, 3, 31, lo, hi));
			}
		}
		emit('sxtw x3, w7', a -> a.sxtw(3, 7));
		emit('ret', a -> a.ret());
		emit('br x9', a -> a.br(9));
		emit('blr x17', a -> a.blr(17));
		emit('brk #0', a -> a.brk());
		emit('mrs x5, TPIDR_EL0', a -> a.mrsTp(5));
		emit('mov x29, sp', a -> a.movSp(29, 31));
		emit('mov sp, x29', a -> a.movSp(31, 29));
		// loads and stores
		for (t in [0, 9, 30])
			for (n in [1, 31, 29]) {
				for (off in [0, 8, 32760, -8, 255, -256])
					emit('ldr ${r(t, true)}, [${r(n, true)}, #$off]', a -> a.ldst(true, 8, false, true, t, n, off));
				for (off in [0, 4, 16380, -4, 3])
					emit('str ${r(t, false)}, [${r(n, true)}, #$off]', a -> a.ldst(false, 4, false, false, t, n, off));
				for (off in [0, 2, -2, 8190])
					emit('ldrh ${r(t, false)}, [${r(n, true)}, #$off]', a -> a.ldst(true, 2, false, false, t, n, off));
				emit('ldrb ${r(t, false)}, [${r(n, true)}, #7]', a -> a.ldst(true, 1, false, false, t, n, 7));
				emit('ldrsb ${r(t, true)}, [${r(n, true)}, #7]', a -> a.ldst(true, 1, true, true, t, n, 7));
				emit('ldrsw ${r(t, true)}, [${r(n, true)}, #12]', a -> a.ldst(true, 4, true, true, t, n, 12));
				emit('strb ${r(t, false)}, [${r(n, true)}, #-1]', a -> a.ldst(false, 1, false, false, t, n, -1));
				emit('ldr d${t}, [${r(n, true)}, #16]', a -> a.ldst(true, 8, false, true, 32 + t, n, 16));
				emit('str d${t}, [${r(n, true)}, #-16]', a -> a.ldst(false, 8, false, true, 32 + t, n, -16));
				emit('ldr ${r(t, true)}, [${r(n, true)}, x5, lsl #3]', a -> a.ldstR(true, 8, false, true, t, n, 5, true));
				emit('str ${r(t, false)}, [${r(n, true)}, x5, lsl #2]', a -> a.ldstR(false, 4, false, false, t, n, 5, true));
				emit('ldrh ${r(t, false)}, [${r(n, true)}, x5, lsl #1]', a -> a.ldstR(true, 2, false, false, t, n, 5, true));
				emit('ldrb ${r(t, false)}, [${r(n, true)}, x5]', a -> a.ldstR(true, 1, false, false, t, n, 5, false));
				emit('ldr d${t}, [${r(n, true)}, x5, lsl #3]', a -> a.ldstR(true, 8, false, true, 32 + t, n, 5, true));
				emit('ldrsw ${r(t, true)}, [${r(n, true)}, x5, lsl #2]', a -> a.ldstR(true, 4, true, true, t, n, 5, true));
			}
		emit('stp x29, x30, [sp, #-16]!', a -> a.pair(false, 29, 30, 31, -16, 1));
		emit('ldp x29, x30, [sp], #16', a -> a.pair(true, 29, 30, 31, 16, 2));
		emit('stp x19, x20, [sp, #32]', a -> a.pair(false, 19, 20, 31, 32, 0));
		emit('ldp d8, d9, [sp, #48]', a -> a.pair(true, 40, 41, 31, 48, 0));
		// floating point
		for (d in [0, 8, 31])
			for (n in [1, 16]) {
				emit('fadd d$d, d$n, d7', a -> a.fop2(2, 32 + d, 32 + n, 39));
				emit('fsub d$d, d$n, d7', a -> a.fop2(3, 32 + d, 32 + n, 39));
				emit('fmul d$d, d$n, d7', a -> a.fop2(0, 32 + d, 32 + n, 39));
				emit('fdiv d$d, d$n, d7', a -> a.fop2(1, 32 + d, 32 + n, 39));
				emit('fmov d$d, d$n', a -> a.fop1(0, 32 + d, 32 + n));
				emit('fabs d$d, d$n', a -> a.fop1(1, 32 + d, 32 + n));
				emit('fneg d$d, d$n', a -> a.fop1(2, 32 + d, 32 + n));
				emit('fsqrt d$d, d$n', a -> a.fop1(3, 32 + d, 32 + n));
				emit('frintm d$d, d$n', a -> a.fop1(4, 32 + d, 32 + n));
				emit('frintp d$d, d$n', a -> a.fop1(5, 32 + d, 32 + n));
				emit('fcmp d$d, d$n', a -> a.fcmp(32 + d, 32 + n));
				emit('fmov x$n, d$d', a -> a.fmovToGpr(n, 32 + d));
				emit('fmov d$d, x$n', a -> a.fmovFromGpr(32 + d, n));
			}
		emit('fcmp d3, #0.0', a -> a.fcmpZero(35));
		// float32 and atomics
		for (d in [0, 8, 31])
			for (n in [1, 16]) {
				emit('fmov s$d, w$n', a -> a.fmovSFromW(32 + d, n));
				emit('fmov w$n, s$d', a -> a.fmovWFromS(n, 32 + d));
				emit('fcvt d$d, s$n', a -> a.fcvtSToD(32 + d, 32 + n));
				emit('fcvt s$d, d$n', a -> a.fcvtDToS(32 + d, 32 + n));
			}
		for (x in [false, true])
			for (t in [0, 7, 30])
				for (n in [1, 16]) {
					emit('ldar ${r(t, x)}, [${r(n, true)}]', a -> a.ldar(x, t, n));
					emit('stlr ${r(t, x)}, [${r(n, true)}]', a -> a.stlr(x, t, n));
					emit('ldaxr ${r(t, x)}, [${r(n, true)}]', a -> a.ldaxr(x, t, n));
					emit('stlxr w17, ${r(t, x)}, [${r(n, true)}]', a -> a.stlxr(x, 17, t, n));
				}
		emit('dmb ish', a -> a.dmbIsh());
		emit('dmb ishst', a -> a.dmbIshst());
		emit('clrex', a -> a.clrex());
		Sys.print(out.toString());
	}
}
