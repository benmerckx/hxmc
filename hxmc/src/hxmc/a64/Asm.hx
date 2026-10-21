package hxmc.a64;

import hxmc.Buf;
import hxmc.Obj;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// AArch64 instruction encoder. Registers: 0-30 the general registers
// (x0-x30; 31 is sp or the zero register depending on the instruction:
// SP and ZR below), 32-63 the floating-point registers (d0-d31). `x`:
// 64-bit operation (else 32-bit, w registers). Branches go to labels
// (patched by `finish`); symbols are relocations of an Obj section.
class Asm {
	public static inline var SP = 31;
	public static inline var ZR = 31;
	public static inline var FP = 29;
	public static inline var LR = 30;
	public static inline var D0 = 32;

	// conditions
	public static inline var EQ = 0;
	public static inline var NE = 1;
	public static inline var HS = 2;
	public static inline var LO = 3;
	public static inline var MI = 4;
	public static inline var PL = 5;
	public static inline var VS = 6;
	public static inline var VC = 7;
	public static inline var HI = 8;
	public static inline var LS = 9;
	public static inline var GE = 10;
	public static inline var LT = 11;
	public static inline var GT = 12;
	public static inline var LE = 13;
	public static inline var AL = 14;

	public var b:Buf;
	public var sec:Null<Section>;
	var labels:Array<Int> = [];
	var fixups:Array<{at:Int, label:Int, kind:Int}> = []; // kind: 0 b/bl (imm26), 1 b.cond/cbz (imm19), 2 adr (imm21)

	public function new(?sec:Section) {
		this.sec = sec;
		b = sec != null ? sec.buf : new Buf(4096);
	}

	public static function regName(r:Int, x:Bool):String {
		if (r >= 32) return "d" + (r - 32);
		if (r == 31) return x ? "sp" : "wsp";
		return (x ? "x" : "w") + r;
	}

	public static function zrName(r:Int, x:Bool):String
		return r == 31 ? (x ? "xzr" : "wzr") : regName(r, x);

	// ---- labels

	public function reset() {
		labels = [];
		fixups = [];
	}

	public function newLabel():Int {
		labels.push(-1);
		return labels.length - 1;
	}

	public function bind(l:Int)
		labels[l] = b.len;

	public function labelPos(l:Int):Int
		return labels[l];

	public inline function pos():Int
		return b.len;

	public function finish() {
		for (f in fixups) {
			var t = labels[f.label];
			if (t < 0) throw "hxmc: unbound label";
			var d = t - f.at;
			var w = b.get32(f.at);
			switch f.kind {
				case 0:
					w |= (d >> 2) & 0x3ffffff;
				case 1:
					if (d >= (1 << 20) || d < -(1 << 20)) throw "hxmc: conditional branch out of range";
					w |= ((d >> 2) & 0x7ffff) << 5;
				case _:
					w |= (d & 3) << 29;
					w |= ((d >> 2) & 0x7ffff) << 5;
			}
			b.set32(f.at, w);
		}
		fixups = [];
	}

	public function reloc(kind:RelKind, s:Symbol, addend:Int) {
		if (sec == null) throw "hxmc: relocation without a section";
		sec.relocs.push(new Reloc(b.len, kind, s, addend));
	}

	inline function w(v:Int)
		b.u32(v);

	static inline function sf(x:Bool):Int
		return x ? 0x80000000 : 0;

	// the opcodes of the instruction groups below, by op
	static final ADD_SUB_R:Vector<Int> = vector(0x0B000000, 0x2B000000, 0x4B000000, 0x6B000000);
	static final ADD_SUB_I:Vector<Int> = vector(0x11000000, 0x31000000, 0x51000000, 0x71000000);
	static final LOGIC_R:Vector<Int> = vector(0x0A000000, 0x2A000000, 0x4A000000, 0x6A000000);
	static final LOGIC_I:Vector<Int> = vector(0x12000000, 0x32000000, 0x52000000, 0x72000000);
	static final DP2:Vector<Int> = vector(0x1AC00800, 0x1AC00C00, 0x1AC02000, 0x1AC02400, 0x1AC02800);
	static final FOP2:Vector<Int> = vector(0x1E600800, 0x1E601800, 0x1E602800, 0x1E603800);
	static final FOP1:Vector<Int> = vector(0x1E604000, 0x1E60C000, 0x1E614000, 0x1E61C000, 0x1E654000, 0x1E64C000);

	// ---- data processing

	// add/sub/adds/subs (shifted register): op 0 add, 1 adds, 2 sub, 3 subs
	public function addSubR(op:Int, x:Bool, d:Int, n:Int, m:Int, shift = 0, amount = 0)
		w(sf(x) | ADD_SUB_R[op] | (shift << 22) | (m << 16) | (amount << 10) | (n << 5) | d);

	// add/sub/adds/subs (immediate 0..4095, optionally shifted by 12)
	public function addSubI(op:Int, x:Bool, d:Int, n:Int, imm:Int, lsl12 = false)
		w(sf(x) | ADD_SUB_I[op] | (lsl12 ? 1 << 22 : 0) | ((imm & 0xfff) << 10) | (n << 5) | d);

	// and/orr/eor/ands (shifted register): op 0 and, 1 orr, 2 eor, 3 ands; invert: bic/orn/eon/bics
	public function logicR(op:Int, x:Bool, d:Int, n:Int, m:Int, invert = false, shift = 0, amount = 0)
		w(sf(x) | LOGIC_R[op] | (invert ? 1 << 21 : 0) | (shift << 22) | (m << 16) | (amount << 10) | (n << 5) | d);

	// and/orr/eor/ands with a bitmask immediate (false: not encodable)
	public function logicI(op:Int, x:Bool, d:Int, n:Int, lo:Int, hi:Int):Bool {
		var e = bitmask(lo, x ? hi : lo, x);
		if (e < 0) return false;
		w(sf(x) | LOGIC_I[op] | (e << 10) | (n << 5) | d);
		return true;
	}

	// the N:immr:imms encoding of a logical immediate (13 bits), or -1: a
	// repeating element of 2..64 bits holding one run of ones (rotated)
	public static function bitmask(lo:Int, hi:Int, x:Bool):Int {
		if (!x) hi = lo;
		if (lo == 0 && hi == 0 || lo == -1 && hi == -1) return -1;
		var size = 2;
		while (size < 64) {
			var periodic = true;
			for (i in size...64)
				if (bit(lo, hi, i) != bit(lo, hi, i % size)) {
					periodic = false;
					break;
				}
			if (periodic) break;
			size <<= 1;
		}
		if (!x && size == 64) return -1;
		var k = 0;
		for (i in 0...size)
			k += bit(lo, hi, i);
		if (k == 0 || k == size) return -1;
		var s = -1;
		for (i in 0...size)
			if (bit(lo, hi, i) == 1 && bit(lo, hi, (i + size - 1) % size) == 0) {
				s = i;
				break;
			}
		for (j in 0...k)
			if (bit(lo, hi, (s + j) % size) != 1) return -1;
		var immr = (size - s) % size;
		var imms = size == 64 ? k - 1 : ((~(size * 2 - 1)) & 0x3f) | (k - 1);
		return ((size == 64 ? 1 : 0) << 12) | (immr << 6) | (imms & 0x3f);
	}

	// bit i of a 64-bit value given by its halves
	static inline function bit(lo:Int, hi:Int, i:Int):Int
		return i < 32 ? (lo >>> i) & 1 : (hi >>> (i - 32)) & 1;

	public function movR(x:Bool, d:Int, m:Int) {
		if (d == m && x) return;
		logicR(1, x, d, ZR, m);
	}

	// mov to or from sp
	public function movSp(d:Int, n:Int)
		addSubI(0, true, d, n, 0);

	public function movz(x:Bool, d:Int, imm16:Int, hw:Int)
		w(sf(x) | 0x52800000 | (hw << 21) | ((imm16 & 0xffff) << 5) | d);

	public function movn(x:Bool, d:Int, imm16:Int, hw:Int)
		w(sf(x) | 0x12800000 | (hw << 21) | ((imm16 & 0xffff) << 5) | d);

	public function movk(x:Bool, d:Int, imm16:Int, hw:Int)
		w(sf(x) | 0x72800000 | (hw << 21) | ((imm16 & 0xffff) << 5) | d);

	// d = a constant (halves of 64 bits)
	public function movI(x:Bool, d:Int, lo:Int, hi:Int) {
		if (!x) hi = 0;
		// the constant's halfwords, lowest first
		inline function part(i:Int):Int
			return i == 0 ? lo & 0xffff : i == 1 ? lo >>> 16 : i == 2 ? hi & 0xffff : hi >>> 16;
		var n = x ? 4 : 2;
		var zeros = 0, ffff = 0;
		for (i in 0...n) {
			if (part(i) == 0) zeros++;
			if (part(i) == 0xffff) ffff++;
		}
		if (zeros == n) {
			movz(x, d, 0, 0);
			return;
		}
		if (ffff > zeros) {
			var first = true;
			for (i in 0...n)
				if (part(i) != 0xffff) {
					if (first) movn(x, d, ~part(i) & 0xffff, i) else movk(x, d, part(i), i);
					first = false;
				}
			if (first) movn(x, d, 0, 0);
			return;
		}
		// a logical immediate in one instruction
		if (zeros < n - 1 && bitmask(lo, hi, x) >= 0) {
			logicI(1, x, d, ZR, lo, hi);
			return;
		}
		var first = true;
		for (i in 0...n)
			if (part(i) != 0) {
				if (first) movz(x, d, part(i), i) else movk(x, d, part(i), i);
				first = false;
			}
	}

	// a 32-bit absolute symbol value: movz + movk with relocations
	public function movSym(x:Bool, d:Int, s:Symbol, addend:Int) {
		reloc(RA64MovwG0Nc, s, addend);
		movz(x, d, 0, 0);
		reloc(RA64MovwG1Nc, s, addend);
		movk(x, d, 0, 1);
	}

	// 0 udiv, 1 sdiv, 2 lslv, 3 lsrv, 4 asrv
	public function dp2(op:Int, x:Bool, d:Int, n:Int, m:Int)
		w(sf(x) | DP2[op] | (m << 16) | (n << 5) | d);

	public function madd(x:Bool, d:Int, n:Int, m:Int, a:Int)
		w(sf(x) | 0x1B000000 | (m << 16) | (a << 10) | (n << 5) | d);

	public function msub(x:Bool, d:Int, n:Int, m:Int, a:Int)
		w(sf(x) | 0x1B008000 | (m << 16) | (a << 10) | (n << 5) | d);

	public function mul(x:Bool, d:Int, n:Int, m:Int)
		madd(x, d, n, m, ZR);

	// bitfield moves: sbfm (signed) / ubfm
	public function bfm(signed:Bool, x:Bool, d:Int, n:Int, immr:Int, imms:Int)
		w(sf(x) | (signed ? 0x13000000 : 0x53000000) | (x ? 1 << 22 : 0) | (immr << 16) | (imms << 10) | (n << 5) | d);

	public function lslI(x:Bool, d:Int, n:Int, sh:Int) {
		var size = x ? 64 : 32;
		bfm(false, x, d, n, (size - sh) % size, size - 1 - sh);
	}

	// ror (immediate): extr d, n, n, #sh
	public function rorI(x:Bool, d:Int, n:Int, sh:Int)
		w((x ? 0x93C00000 : 0x13800000) | (n << 16) | (sh << 10) | (n << 5) | d);

	public function lsrI(x:Bool, d:Int, n:Int, sh:Int)
		bfm(false, x, d, n, sh, x ? 63 : 31);

	public function asrI(x:Bool, d:Int, n:Int, sh:Int)
		bfm(true, x, d, n, sh, x ? 63 : 31);

	public function sxtw(d:Int, n:Int)
		bfm(true, true, d, n, 0, 31);

	public function neg(x:Bool, d:Int, m:Int)
		addSubR(2, x, d, ZR, m);

	public function mvn(x:Bool, d:Int, m:Int)
		logicR(1, x, d, ZR, m, true);

	public function cmpR(x:Bool, n:Int, m:Int)
		addSubR(3, x, ZR, n, m);

	public function cmpI(x:Bool, n:Int, imm:Int)
		addSubI(3, x, ZR, n, imm);

	public function cmnI(x:Bool, n:Int, imm:Int)
		addSubI(1, x, ZR, n, imm);

	public function tstR(x:Bool, n:Int, m:Int)
		logicR(3, x, ZR, n, m);

	public function csel(x:Bool, d:Int, n:Int, m:Int, cond:Int)
		w(sf(x) | 0x1A800000 | (m << 16) | (cond << 12) | (n << 5) | d);

	public function cset(x:Bool, d:Int, cond:Int)
		w(sf(x) | 0x1A800400 | (ZR << 16) | ((cond ^ 1) << 12) | (ZR << 5) | d);

	// ---- branches

	public function bl(l:Int) {
		fixups.push({at: b.len, label: l, kind: 0});
		w(0x94000000);
	}

	public function bLabel(l:Int) {
		fixups.push({at: b.len, label: l, kind: 0});
		w(0x14000000);
	}

	public function bcond(cond:Int, l:Int) {
		fixups.push({at: b.len, label: l, kind: 1});
		w(0x54000000 | cond);
	}

	public function cbz(x:Bool, r:Int, l:Int, nz = false) {
		fixups.push({at: b.len, label: l, kind: 1});
		w(sf(x) | (nz ? 0x35000000 : 0x34000000) | r);
	}

	public function adrLabel(d:Int, l:Int) {
		fixups.push({at: b.len, label: l, kind: 2});
		w(0x10000000 | d);
	}

	public function blSym(s:Symbol) {
		reloc(RA64Call26, s, 0);
		w(0x94000000);
	}

	public function bSym(s:Symbol) {
		reloc(RA64Jump26, s, 0);
		w(0x14000000);
	}

	public function br(n:Int)
		w(0xD61F0000 | (n << 5));

	public function blr(n:Int)
		w(0xD63F0000 | (n << 5));

	public function ret()
		w(0xD65F03C0);

	public function brk()
		w(0xD4200000);

	// ---- symbols and TLS

	// d = address of symbol + addend (adrp + add)
	public function adrSym(d:Int, s:Symbol, addend:Int) {
		reloc(RA64AdrPage21, s, addend);
		w(0x90000000 | d);
		reloc(RA64AddLo12, s, addend);
		addSubI(0, true, d, d, 0);
	}

	// adrp d, symbol (for a load or store with a :lo12: offset)
	public function adrp(d:Int, s:Symbol, addend:Int) {
		reloc(RA64AdrPage21, s, addend);
		w(0x90000000 | d);
	}

	public function mrsTp(d:Int)
		w(0xD53BD040 | d);

	// d = the address of a thread-local variable: tp + tprel(sym)
	public function tlsAddr(d:Int, s:Symbol) {
		mrsTp(d);
		reloc(RA64TlsLeHi12, s, 0);
		addSubI(0, true, d, d, 0, true);
		reloc(RA64TlsLeLo12Nc, s, 0);
		addSubI(0, true, d, d, 0);
	}

	// ---- loads and stores
	// size: 1, 2, 4, 8 bytes; float: d register (size 8)

	static function ldstBase(size:Int, load:Bool, signed:Bool, x:Bool, float:Bool):Int {
		if (float) return load ? 0x3D400000 | (3 << 30) : 0x3D000000 | (3 << 30);
		var sz = size == 8 ? 3 : size == 4 ? 2 : size == 2 ? 1 : 0;
		var opc = !load ? 0 : (signed ? (x ? 2 : 3) : 1);
		return (sz << 30) | 0x39000000 | (opc << 22);
	}

	static inline function scaleOf(size:Int):Int
		return size == 8 ? 3 : size == 4 ? 2 : size == 2 ? 1 : 0;

	// [n + off]: scaled unsigned offset when aligned and in range, else unscaled 9-bit; false: neither
	public function ldst(load:Bool, size:Int, signed:Bool, x:Bool, t:Int, n:Int, off:Int):Bool {
		var float = t >= 32;
		var base = ldstBase(size, load, signed, x, float);
		var sc = scaleOf(size);
		if (off >= 0 && off & ((1 << sc) - 1) == 0 && (off >> sc) < 4096) {
			w(base | ((off >> sc) << 10) | (n << 5) | (t & 31));
			return true;
		}
		if (off >= -256 && off < 256) {
			// ldur/stur: bit 24 clear, imm9 at 12
			w((base & ~0x01000000) | ((off & 0x1ff) << 12) | (n << 5) | (t & 31));
			return true;
		}
		return false;
	}

	// [n + m << (shift ? scale : 0)]
	public function ldstR(load:Bool, size:Int, signed:Bool, x:Bool, t:Int, n:Int, m:Int, shift:Bool) {
		var float = t >= 32;
		var base = ldstBase(size, load, signed, x, float) & ~0x01000000;
		// register offset: bit 21, option 011 (lsl), S
		w(base | 0x00200800 | (m << 16) | (3 << 13) | ((shift ? 1 : 0) << 12) | (n << 5) | (t & 31));
	}

	// a load or store at a symbol's :lo12: offset (after adrp)
	public function ldstSymLo(load:Bool, size:Int, signed:Bool, x:Bool, t:Int, n:Int, s:Symbol, addend:Int) {
		var float = t >= 32;
		reloc(float || size == 8 ? RA64Ldst64Lo12 : size == 4 ? RA64Ldst32Lo12 : size == 2 ? RA64Ldst16Lo12 : RA64Ldst8Lo12, s, addend);
		w(ldstBase(size, load, signed, x, float) | (n << 5) | (t & 31));
	}

	// stp/ldp of 64-bit registers (or d registers): mode 0 signed offset, 1 pre-index, 2 post-index
	public function pair(load:Bool, t1:Int, t2:Int, n:Int, off:Int, mode:Int) {
		var float = t1 >= 32;
		var base = float ? 0x6C000000 : 0xA8000000;
		var m = mode == 0 ? 0x01000000 : mode == 1 ? 0x01800000 : 0x00800000;
		w(base | m | (load ? 0x00400000 : 0) | (((off >> 3) & 0x7f) << 15) | ((t2 & 31) << 10) | (n << 5) | (t1 & 31));
	}

	// ---- floating point (d registers 32-63)

	// 0 fmul, 1 fdiv, 2 fadd, 3 fsub
	public function fop2(op:Int, d:Int, n:Int, m:Int)
		w(FOP2[op] | ((m & 31) << 16) | ((n & 31) << 5) | (d & 31));

	// 0 fmov, 1 fabs, 2 fneg, 3 fsqrt, 4 frintm (floor), 5 frintp (ceil)
	public function fop1(op:Int, d:Int, n:Int)
		w(FOP1[op] | ((n & 31) << 5) | (d & 31));

	public function fmovR(d:Int, n:Int) {
		if (d != n) fop1(0, d, n);
	}

	public function fcmp(n:Int, m:Int)
		w(0x1E602000 | ((m & 31) << 16) | ((n & 31) << 5));

	public function fcmpZero(n:Int)
		w(0x1E602008 | ((n & 31) << 5));

	// scvtf d, w/x
	public function scvtf(x:Bool, d:Int, n:Int)
		w(sf(x) | 0x1E620000 | (n << 5) | (d & 31));

	// fcvtzs w/x, d
	public function fcvtzs(x:Bool, d:Int, n:Int)
		w(sf(x) | 0x1E780000 | ((n & 31) << 5) | d);

	// fmov x, d / fmov d, x
	public function fmovToGpr(d:Int, n:Int)
		w(0x9E660000 | ((n & 31) << 5) | d);

	public function fmovFromGpr(d:Int, n:Int)
		w(0x9E670000 | (n << 5) | (d & 31));

	// float32: fmov s, w / fmov w, s; fcvt d, s / fcvt s, d
	public function fmovSFromW(d:Int, n:Int)
		w(0x1E270000 | (n << 5) | (d & 31));

	public function fmovWFromS(d:Int, n:Int)
		w(0x1E260000 | ((n & 31) << 5) | d);

	public function fcvtSToD(d:Int, n:Int)
		w(0x1E22C000 | ((n & 31) << 5) | (d & 31));

	public function fcvtDToS(d:Int, n:Int)
		w(0x1E624000 | ((n & 31) << 5) | (d & 31));

	// ---- atomics (hxmc.unsafe.Atomic): load-acquire, store-release and the
	// exclusive pair (no LSE: every ARMv8.0 machine has these)
	static inline function szBits(x:Bool):Int
		return x ? 0xC0000000 : 0x80000000;

	public function ldar(x:Bool, t:Int, n:Int)
		w(szBits(x) | 0x08DFFC00 | (n << 5) | t);

	public function stlr(x:Bool, t:Int, n:Int)
		w(szBits(x) | 0x089FFC00 | (n << 5) | t);

	public function ldaxr(x:Bool, t:Int, n:Int)
		w(szBits(x) | 0x085FFC00 | (n << 5) | t);

	// stlxr ws, t, [n]: ws 0 when the store succeeded
	public function stlxr(x:Bool, s:Int, t:Int, n:Int)
		w(szBits(x) | 0x0800FC00 | (s << 16) | (n << 5) | t);

	public function dmbIsh()
		w(0xD5033BBF);

	public function clrex()
		w(0xD5033F5F);
}
