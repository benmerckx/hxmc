package hxmc.x64;

import hxmc.Mir;
import hxmc.Abi;
import hxmc.Lir;
import hxmc.x64.Asm;
import hxmc.CallConv.ArgLoc;
import hxmc.CAbi.CPart;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// x86-64 LIR operations (LIns.op)
enum abstract XOp(Int) to Int from Int {
	var MOV; // d <- s1 (gpr or xmm)
	var MOVI; // d <- imm (imm2: high half when size 8)
	var MOVF; // d (xmm) <- f (constant pool)
	var LEA; // d <- address
	var LOAD; // d <- [mem] (size; flag: sign-extend)
	var STORE; // [mem] <- s1
	var STOREI; // [mem] <- imm
	var ALU; // d <- d (cond: ADD/OR/AND/SUB/XOR) s1
	var ALUI; // d <- d op imm
	var IMUL; // d <- d * s1
	var IMULI; // d <- s1 * imm
	var SHIFT; // d <- d (cond: SHL/SHR/SAR) cl
	var SHIFTI; // d <- d op imm
	var NEG;
	var NOT;
	var CQO; // rdx <- sign of rax (size)
	var IDIV; // rax, rdx <- rdx:rax / s1 (cond 6: unsigned)
	var CMP; // flags <- s1 - s2
	var CMPI; // flags <- s1 - imm
	var TESTI; // flags <- s1 & imm
	var CMPM; // flags <- s1 - [mem] (size)
	var CMPMI; // flags <- [mem] - imm (size)
	var ALUM; // d <- d (cond) [mem] (size)
	var TEST; // flags <- s1 & s2
	var UCOMI; // flags <- s1 <=> s2 (doubles)
	var SETCC; // d <- cond ? 1 : 0 (32 bits)
	var CMOV; // d <- cond ? s1 : d
	var FOP; // d <- d (cond: 0x58 add, 0x59 mul, 0x5c sub, 0x5e div) s1
	var FSQRT; // d <- sqrt s1
	var FMASK; // d <- d (cond: 0x57 xorpd, 0x54 andpd) [mask imm: 0 sign bit, 1 all but the sign bit]
	var CVTI2F; // d (xmm) <- s1 (size)
	var CVTF2I; // d <- s1 (xmm), truncating (size)
	var MOVQXR; // d (xmm) <- s1 bits
	var MOVQRX; // d <- s1 (xmm) bits
	var CALL; // sym, or s1; uses: argument registers
	var RET; // uses: the result register
	var JMP; // target
	var JCC; // cond -> target
	var JTABLE; // d: table address (clobbered), s1: index, s2: scratch; table
	var LEATABLE; // d <- address of the jump table of the next JTABLE (table)
	var GSLOAD; // d <- gs:[imm] (Windows)
	var TLSLOAD; // d <- fs:[sym]
	var TLSSTORE; // fs:[sym] <- s1
	var UD2;
	// (hxmc.unsafe: MirBuild.intrinsic)
	var XCHG; // d <-> [mem] (size)
	var XADD; // lock xadd [mem], d: d <- old, [mem] += d (size)
	var CMPXCHG; // lock cmpxchg [mem], s1: rax expected, then the old value (size)
	var MFENCE;
	var CVTSS2SD; // d (xmm) <- s1 (xmm, a float32)
	var CVTSD2SS; // d (xmm, a float32) <- s1 (xmm)
	var MOVDXR; // d (xmm) <- s1 (32 bits)
	var MOVDRX; // d (32 bits) <- s1 (xmm)
	var FOPK; // d <- d (cond: as FOP) f (constant pool)
	// vectors (hxmc.simd: SSE4.1, docs/plans/simd.md): imm the opcode
	// (0x0fxx, 0x0f38xx, 0x0f3axx), cond the prefix | 0x100 REX.W | 0x200
	// the operands swapped (reg is s1) | the /digit << 12, imm2 an immediate
	// byte (-1: none)
	var VX; // d <- d op s1
	var VXU; // d <- op s1 (xmm or general registers)
	var VXI; // d <- d op imm2 (a /digit form: shifts by an immediate)
	var VXK; // d <- d op [the constant of uses: four 32-bit words]
	var VCONST; // d <- the constant of uses
	var PTEST; // flags <- s1 & s1 (ptest)
}

// Mir -> LIR for x86-64 (System V and Win64: CallConv); the walk, the
// edges, switches and calls are IselBase's.
class Isel extends hxmc.IselBase implements hxmc.Target.Selector {
	static inline var RAX = 0;
	static inline var RCX = 1;
	static inline var RDX = 2;
	static inline var RSP = 4;
	static inline var XMM0 = 16;

	// the allocatable registers in order of preference (System V, Win64; rbp
	// last, and not with frame pointers: it holds the frame record, Emit)
	static final GPRS:Vector<Int> = vector(1, 2, 6, 7, 8, 9, 10, 11, 0, 3, 12, 13, 14, 15, 5);
	static final GPRS_FP:Vector<Int> = vector(1, 2, 6, 7, 8, 9, 10, 11, 0, 3, 12, 13, 14, 15);
	static final WIN_GPRS:Vector<Int> = vector(1, 2, 8, 9, 10, 11, 0, 3, 6, 7, 12, 13, 14, 15, 5);
	static final WIN_GPRS_FP:Vector<Int> = vector(1, 2, 8, 9, 10, 11, 0, 3, 6, 7, 12, 13, 14, 15);
	static final FPRS:Vector<Int> = vector(16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);

	public var win:Bool;

	var flagsOf = new Map<Int, Int>(); // comparisons whose flags the branch after them reads
	var memFolds = new Map<Int, Bool>(); // loads that are memory operands of their user
	var testFolds = new Map<Int, Bool>(); // x & constant used only by a comparison with 0 (TESTI)
	var indexFolds = new Map<Int, Bool>(); // x + y used only as the base of accesses: their base and index

	// whether load v is a memory operand of its user (marks it folded)
	function memFold(v:Int):Bool {
		return memFolds.exists(v);
	}

	public function new(abi:Abi) {
		super(abi);
		win = abi.os == "windows";
		if (win) gprs = abi.framePointers ? WIN_GPRS_FP : WIN_GPRS else gprs = abi.framePointers ? GPRS_FP : GPRS;
		fprs = FPRS;
		vprs = FPRS;
		fprBase = 16;
		opMov = MOV;
		opLoad = LOAD;
		opStore = STORE;
		opJmp = JMP;
		opCall = CALL;
		opRet = RET;
		opTeb = GSLOAD;
	}

	// ---- RegTarget

	public function defsUses(i:LIns, defs:hxmc.Regalloc.RegList, uses:hxmc.Regalloc.RegList) {
		inline function mem() {
			if (i.base >= 0) uses.push(i.base);
			if (i.index >= 0) uses.push(i.index);
		}
		switch (i.op : XOp) {
			case MOV | CVTI2F | CVTF2I | MOVQXR | MOVQRX | FSQRT | CVTSS2SD | CVTSD2SS | MOVDXR | MOVDRX:
				defs.push(i.d);
				uses.push(i.s1);
			case XCHG | XADD:
				defs.push(i.d);
				uses.push(i.d);
				mem();
			case CMPXCHG:
				defs.push(RAX);
				uses.push(RAX);
				uses.push(i.s1);
				mem();
			case MFENCE:
			case MOVI | MOVF | SETCC | TLSLOAD | LEATABLE | GSLOAD:
				defs.push(i.d);
			case LEA | LOAD:
				defs.push(i.d);
				mem();
			case STORE:
				uses.push(i.s1);
				mem();
			case STOREI:
				mem();
			case ALU | IMUL | FOP | CMOV:
				defs.push(i.d);
				uses.push(i.d);
				uses.push(i.s1);
			case VX:
				defs.push(i.d);
				uses.push(i.d);
				uses.push(i.s1);
			case VXU:
				defs.push(i.d);
				uses.push(i.s1);
			case VXI | VXK:
				defs.push(i.d);
				uses.push(i.d);
			case VCONST:
				defs.push(i.d);
			case PTEST:
				uses.push(i.s1);
			case ALUI | SHIFTI | NEG | NOT | FMASK | FOPK:
				defs.push(i.d);
				uses.push(i.d);
			case IMULI:
				defs.push(i.d);
				uses.push(i.s1);
			case SHIFT:
				defs.push(i.d);
				uses.push(i.d);
				uses.push(RCX);
			case CQO:
				defs.push(RDX);
				uses.push(RAX);
			case IDIV:
				defs.push(RAX);
				defs.push(RDX);
				uses.push(RAX);
				uses.push(RDX);
				uses.push(i.s1);
			case CMP | TEST | UCOMI:
				uses.push(i.s1);
				uses.push(i.s2);
			case CMPI | TESTI:
				uses.push(i.s1);
			case CMPM:
				uses.push(i.s1);
				mem();
			case CMPMI:
				mem();
			case ALUM:
				defs.push(i.d);
				uses.push(i.d);
				mem();
			case CALL:
				if (i.s1 >= 0) uses.push(i.s1);
				for (u in i.uses)
					uses.push(u);
				for (r in cc.callerSaved)
					defs.push(r);
			case RET:
				for (u in i.uses)
					uses.push(u);
			case JTABLE:
				uses.push(i.d);
				uses.push(i.s1);
				defs.push(i.d);
				defs.push(i.s2);
			case TLSSTORE:
				uses.push(i.s1);
			case JMP | JCC | UD2:
		}
	}

	public function isBranch(i:LIns):Bool
		return i.op == JMP || i.op == JCC || i.op == JTABLE || i.op == UD2;

	// ---- selection

	inline function isF(v:Int):Bool
		return m.vals[v].ty == F64;

	// a constant without a symbol
	function plainImm(v:Int):Null<Int>
		return isymOf(v) == null ? immOf(v) : null;

	// a 32-bit constant usable as an immediate (sign-extended for 64-bit
	// operations), possibly symbolic (isymOf)
	function immOf(v:Int):Null<Int> {
		var i = m.vals[v];
		if (i.op != Const) return null;
		if (i.ty == I32 || i.sym != null) return i.imm;
		if (i.imm2 == (i.imm < 0 ? -1 : 0)) return i.imm;
		return null;
	}

	// x86-64 folds loads into the comparisons and arithmetic that use them,
	// x & constant into TESTI, address arithmetic into displacements, and
	// constants and addresses into their users
	override function prepare() {
		var mf = m;
		var addrUses = hxmc.Lir.Arrays.filled(mf.vals.length, 0); // uses as the base of a load or store
		var baseUses = hxmc.Lir.Arrays.filled(mf.vals.length, 0); // (of those without an index)
		for (b in mf.blocks)
			for (i in b.ins)
				if ((i.op == Load || i.op == Store) && i.imm > -0x40000000 && i.imm < 0x40000000) {
					addrUses[i.a]++;
					if (i.b < 0 && (i.op == Load || i.c != i.a)) baseUses[i.a]++;
				}
		// loads used once by an integer comparison or operation later in their
		// block, with no store or call between: memory operands of the
		// comparison or operation (a sign extension: movsxd from memory)
		for (b in mf.blocks) {
			var ins = b.ins;
			for (k in 0...ins.length) {
				var c = ins[k];
				// the candidates in order (-1: none)
				var cand0 = -1, cand1 = -1;
				if (c.op == Cmp && mf.vals[c.a].ty != F64) {
					var bImm = immOf(c.b) != null, aImm = immOf(c.a) != null;
					if (bImm) {
						if (isymOf(c.b) == null) cand0 = c.a;
					} else if (!aImm) {
						cand0 = c.b;
						cand1 = c.a;
					}
				} else if ((c.op == Add || c.op == Sub || c.op == And || c.op == Or || c.op == Xor) && c.ty != F64) {
					// the second operand (either, when commutative); not with an
					// immediate operand (those take ALUI or LEA)
					if (immOf(c.a) != null || immOf(c.b) != null) continue;
					cand0 = c.b;
					if (c.op != Sub) cand1 = c.a;
					if (c.a == c.b) continue;
				} else if (c.op == SExt) {
					cand0 = c.a;
				} else continue;
				for (q in 0...2) {
					var x = q == 0 ? cand0 : cand1;
					if (x < 0) break;
					var l = mf.vals[x];
					if (l.op != Load || l.block != b || useCount[x] != 1 || l.ty == F64) continue;
					if (l.size != (l.ty == I32 ? 4 : 8)) continue;
					var j = k;
					var ok = false;
					while (j-- > 0) {
						var y = ins[j];
						if (y == l) {
							ok = true;
							break;
						}
						if (y.op == Store || y.op == Call || y.op == TlsStore) break;
					}
					if (ok) {
						memFolds[x] = true;
						folded[x] = true;
						break;
					}
				}
			}
		}
		// x & constant compared with 0 (== or !=), used only there, in its
		// block: a TESTI of the comparison
		// (also when value numbering left one x & constant for several such
		// comparisons: each tests x, the and is not computed nor kept live)
		testFolds = new Map();
		indexFolds = new Map();
		var testUses = new Map<Int, Int>();
		for (b in mf.blocks)
			for (c in b.ins) {
				if (c.op != Cmp || c.imm != (CEq : Int) && c.imm != (CNe : Int)) continue;
				if (immOf(c.b) != 0 || isymOf(c.b) != null) continue;
				var x = mf.vals[c.a];
				if (x.op != And || x.ty == F64) continue;
				var k = immOf(x.b);
				if (k == null || isymOf(x.b) != null || folded[x.a]) continue;
				var n = testUses.exists(x.id) ? testUses.get(x.id) + 1 : 1;
				testUses.set(x.id, n);
				if (n == useCount[x.id]) {
					testFolds[x.id] = true;
					folded[x.id] = true;
				}
			}
		// x + constant used only as the address of loads and stores: their
		// displacement (a symbolic constant, a global's offset, relocated)
		for (b in mf.blocks)
			for (i in b.ins) {
				if (i.op != Add || i.ty != I64 || addrUses[i.id] == 0 || addrUses[i.id] != useCount[i.id]) continue;
				var c = immOf(i.b);
				if (c == null) {
					// x + y used only as the base of accesses without an index: (x,y)
					if (baseUses[i.id] == useCount[i.id] && i.a != i.b && !folded[i.a] && !folded[i.b] && mf.vals[i.a].op != Const && mf.vals[i.b].op != Const) {
						folded[i.id] = true;
						indexFolds[i.id] = true;
					}
					continue;
				}
				if (c <= -0x40000000 || c >= 0x40000000 || folded[i.a] && mf.vals[i.a].op == Const) continue;
				folded[i.id] = true;
			}
		// constants and symbol addresses used once by a foldable user are not computed on their own
		for (b in mf.blocks)
			for (i in b.ins)
				if ((i.op == Const && immOf(i.id) != null) || i.op == SymAddr || i.op == StackAddr || i.op == ConstF) folded[i.id] = true;
		// vector constants: made where used (pxor, pcmpeqd, a load from
		// .rodata), or the memory operand of their user (vbk), never a
		// register of their own across the code
		for (b in mf.blocks)
			for (i in b.ins)
				if (i.op == VConst) folded[i.id] = true;
	}

	override function materialize(i:MIns, r:Int) {
		// into a physical register: after the pending instruction (it may be a call)
		if (r < LFunc.NPHYS) flush();
		switch i.op {
			case Const:
				var x = new LIns(MOVI);
				push(x);
				x.flag = true; // no xor: flags may be live
				x.d = r;
				x.imm = i.imm;
				x.isym = i.sym;
				x.imm2 = i.ty == I32 ? 0 : i.imm2;
				x.size = sz(i.ty);
			case SymAddr:
				var x = new LIns(LEA);
				push(x);
				x.d = r;
				x.sym = i.sym;
				x.disp = i.imm;
			case StackAddr:
				var x = new LIns(LEA);
				push(x);
				x.d = r;
				x.base = LIns.FRAME;
				x.slot = i.imm;
			case ConstF:
				var x = new LIns(MOVF);
				push(x);
				x.d = r;
				x.f = i.f;
			case VConst:
				var x = new LIns(VCONST);
				push(x);
				x.d = r;
				x.uses = Vector.fromArrayCopy([for (w in i.cases) w]);
			case _:
				throw "hxmc: cannot materialize " + MFunc.opName(i.op);
		}
	}

	// a memory operand for base value + index value * scale + disp: folds
	// symbol and frame addresses
	function memOf(x:LIns, base:Int, index:Int, scale:Int, disp:Int) {
		var bi = m.vals[base];
		x.disp = disp;
		x.scale = scale;
		if (folded[base] && bi.op == Add && indexFolds[base]) {
			x.base = use(bi.a);
			x.index = use(bi.b);
			x.scale = 1;
		} else if (folded[base] && bi.op == Add) {
			var c = m.vals[bi.b];
			x.disp += c.imm;
			x.dsym = c.sym;
			x.base = use(bi.a);
			if (index >= 0) x.index = use(index);
		} else if (folded[base] && bi.op == SymAddr && index < 0) {
			x.sym = bi.sym;
			x.disp += bi.imm;
		} else if (folded[base] && bi.op == StackAddr) {
			x.base = LIns.FRAME;
			x.slot = bi.imm;
			if (index >= 0) {
				// frame + index: compute the address first
				var r = f.newReg(false);
				var l = new LIns(LEA);
				push(l);
				l.d = r;
				l.base = LIns.FRAME;
				l.slot = bi.imm;
				x.base = r;
				x.slot = -1;
				x.index = use(index);
			}
		} else {
			x.base = use(base);
			if (index >= 0) x.index = use(index);
		}
	}

	static function intCond(c:Int):hxmc.x64.Asm.CC
		return switch (c : Cond) {
			case CEq: E;
			case CNe: NE;
			case CLt: L;
			case CLe: LE;
			case CGt: G;
			case CGe: GE;
			case CULt: B;
			case CULe: BE;
			case CUGt: A;
			case CUGe: AE;
			case _: throw "float condition";
		};

	// sets the flags for a comparison; returns the x86 condition (for floats
	// FEq/FNe need the parity flag too: returns -1/-2 for them)
	function compare(c:Int, a:Int, b:Int):Int {
		var t = m.vals[a].ty;
		if (t == F64) {
			var x = emit(UCOMI);
			switch (c : Cond) {
				case FLt | FLe:
					// a < b is b > a: "above" is false when unordered
					x.s1 = use(b);
					x.s2 = use(a);
					return c == FLt ? A : AE;
				case FGt | FGe:
					x.s1 = use(a);
					x.s2 = use(b);
					return c == FGt ? A : AE;
				case FEq:
					x.s1 = use(a);
					x.s2 = use(b);
					return -1;
				case _:
					x.s1 = use(a);
					x.s2 = use(b);
					return -2;
			}
		}
		var imm = immOf(b);
		// a load used only here: a memory operand
		if (imm != null && isymOf(b) == null && memFold(a)) {
			var l = m.vals[a];
			var x = emit(CMPMI);
			memOf(x, l.a, l.b, l.imm2, l.imm);
			x.imm = imm;
			x.size = sz(t);
			return intCond(c);
		}
		if (imm == null && immOf(a) == null && memFold(b)) {
			var l = m.vals[b];
			var x = emit(CMPM);
			x.s1 = use(a);
			memOf(x, l.a, l.b, l.imm2, l.imm);
			x.size = sz(t);
			return intCond(c);
		}
		if (imm == null && immOf(a) == null && memFold(a)) {
			var l = m.vals[a];
			var x = emit(CMPM);
			x.s1 = use(b);
			memOf(x, l.a, l.b, l.imm2, l.imm);
			x.size = sz(t);
			return intCond(swapCond(c));
		}
		if (imm != null) {
			if (imm == 0 && isymOf(b) == null && (c == CEq || c == CNe) && testFolds.exists(a)) {
				var y = m.vals[a];
				var x = emit(TESTI);
				x.s1 = use(y.a);
				x.imm = immOf(y.b);
				x.size = sz(t);
			} else if (imm == 0 && isymOf(b) == null && (c == CEq || c == CNe)) {
				var x = emit(TEST);
				x.s1 = use(a);
				x.s2 = x.s1;
				x.size = sz(t);
			} else {
				var x = emit(CMPI);
				x.s1 = use(a);
				x.imm = imm;
				x.isym = isymOf(b);
				x.size = sz(t);
			}
			return intCond(c);
		}
		var ia = immOf(a);
		if (ia != null) {
			var x = emit(CMPI);
			x.s1 = use(b);
			x.imm = ia;
			x.isym = isymOf(a);
			x.size = sz(t);
			return intCond(swapCond(c));
		}
		var x = emit(CMP);
		x.s1 = use(a);
		x.s2 = use(b);
		x.size = sz(t);
		return intCond(c);
	}

	function setcc(d:Int, cond:Int) {
		var x = emit(SETCC);
		x.d = d;
		x.cond = cond;
	}

	function jcc(cond:Int, t:LBlock) {
		var x = emit(JCC);
		x.cond = cond;
		x.target = t;
	}

	override function ins(i:MIns, b:MBlock, next:Null<MBlock>) {
		switch i.op {
			case VOp:
				vop(i);
			case VConst:
			case Phi:
			case Param:
				param(i);
			case Const | SymAddr | StackAddr:
				if (!folded[i.id]) materialize(i, reg(i.id));
			case ConstF:
				// (folded: loaded where used, or a memory operand: FOPK)
				if (!folded[i.id]) {
					var x = emit(MOVF);
					x.d = reg(i.id);
					x.f = i.f;
				}
			case TlsLoad if (tlsBase >= 0):
				var x = emit(LOAD);
				x.d = reg(i.id);
				x.base = tlsBase;
				x.secrel = i.sym;
				x.size = 8;
			case TlsStore if (tlsBase >= 0):
				var v = use(i.a);
				var x = emit(STORE);
				x.s1 = v;
				x.base = tlsBase;
				x.secrel = i.sym;
				x.size = 8;
			case TlsLoad | TlsStore if (abi.tls != LocalExec):
				throw new hxmc.MirBuild.Unsupported("thread-local variables: TLS model " + abi.tls);
			case TlsLoad:
				var x = emit(TLSLOAD);
				x.d = reg(i.id);
				x.sym = i.sym;
			case TlsStore:
				var x = emit(TLSSTORE);
				x.s1 = use(i.a);
				x.sym = i.sym;
			case Copy:
				mov(reg(i.id), use(i.a));
			case And if (testFolds.exists(i.id)): // (TESTI of its comparison)
			case Add if (folded[i.id]): // (the displacement of the loads and stores it is the address of)
			case Add | Sub | And | Or | Xor:
				var d = reg(i.id);
				var size = sz(i.ty);
				var imm = immOf(i.b);
				if ((i.op == Add || i.op == Sub && imm != null && imm != -2147483648) && imm != null && isymOf(i.b) == null && !folded[i.a]) {
					var x = emit(LEA);
					x.d = d;
					x.base = use(i.a);
					x.disp = i.op == Add ? imm : -imm;
					x.size = size;
					return;
				}
				var o = switch i.op {
					case Add: Asm.ADD;
					case Sub: Asm.SUB;
					case And: Asm.AND;
					case Or: Asm.OR;
					case _: Asm.XOR;
				};
				// a load used only here: a memory operand (the other operand is the destination)
				if (memFold(i.b) || i.op != Sub && memFold(i.a)) {
					var l = memFold(i.b) ? i.b : i.a;
					var other = l == i.b ? i.a : i.b;
					var lv = m.vals[l];
					mov(d, use(other), size);
					var x = emit(ALUM);
					x.d = d;
					memOf(x, lv.a, lv.b, lv.imm2, lv.imm);
					x.cond = switch i.op {
						case Add: Asm.ADD;
						case Sub: Asm.SUB;
						case And: Asm.AND;
						case Or: Asm.OR;
						case _: Asm.XOR;
					};
					x.size = size;
					return;
				}
				// commutative: the operand that dies here as the destination
				var a = i.a, c = i.b;
				if (imm == null && i.op != Sub && immOf(a) != null) {
					a = i.b;
					c = i.a;
					imm = immOf(c);
				}
				mov(d, use(a), size);
				if (imm != null) {
					var x = emit(ALUI);
					x.d = d;
					x.cond = o;
					x.imm = imm;
					x.isym = isymOf(c);
					x.size = size;
				} else {
					var x = emit(ALU);
					x.d = d;
					x.s1 = use(c);
					x.cond = o;
					x.size = size;
				}
			case Mul:
				var d = reg(i.id);
				var size = sz(i.ty);
				var imm = plainImm(i.b);
				if (imm != null && imm > 1 && imm & (imm - 1) == 0) {
					// by a power of two: a shift
					mov(d, use(i.a), size);
					var x = emit(SHIFTI);
					x.d = d;
					x.cond = Asm.SHL;
					x.imm = log2(imm);
					x.size = size;
				} else if (imm != null) {
					var x = emit(IMULI);
					x.d = d;
					x.s1 = use(i.a);
					x.imm = imm;
					x.size = size;
				} else {
					mov(d, use(i.a), size);
					var x = emit(IMUL);
					x.d = d;
					x.s1 = use(i.b);
					x.size = size;
				}
			case Shl | Sar | Shr:
				var d = reg(i.id);
				var size = sz(i.ty);
				var o = i.op == Shl ? Asm.SHL : i.op == Sar ? Asm.SAR : Asm.SHR;
				var imm = plainImm(i.b);
				mov(d, use(i.a), size);
				if (imm != null) {
					var x = emit(SHIFTI);
					x.d = d;
					x.cond = o;
					x.imm = imm & (size == 8 ? 63 : 31);
					x.size = size;
				} else {
					mov(RCX, use(i.b), 8);
					var x = emit(SHIFT);
					x.d = d;
					x.cond = o;
					x.size = size;
				}
			case NullCheck | New | NewDyn | InitField | GetField | SetField | FieldAddr | EnumTag | TypeTest | Box | Unbox | VirtualCall | ClosureCall | AnonGet |
				AnonTest | AnonStore | AnonCall | ArrayLength | ArrayGet | ArraySet | ArrayPush | NewArray | ArrayInit | NewNArray | NArrayInit | NArrayLength |
				NArrayGet | NArraySet | NArrayDyn | RefStore | Tag | Untag:
				objectLevel(i);
			case Rotr:
				var d = reg(i.id);
				var size = sz(i.ty);
				mov(d, use(i.a), size);
				var x = emit(SHIFTI);
				x.d = d;
				x.cond = Asm.ROR;
				x.imm = m.vals[i.b].imm & (size == 8 ? 63 : 31);
				x.size = size;
			case Neg | Not:
				var d = reg(i.id);
				var size = sz(i.ty);
				mov(d, use(i.a), size);
				var x = emit(i.op == Neg ? NEG : NOT);
				x.d = d;
				x.size = size;
			case Div | Rem:
				var size = sz(i.ty);
				var dv = use(i.b);
				mov(RAX, use(i.a), size);
				var c = emit(CQO);
				c.size = size;
				var x = emit(IDIV);
				x.s1 = dv;
				x.size = size;
				mov(reg(i.id), i.op == Div ? RAX : RDX, size);
			case UDiv | URem:
				var size = sz(i.ty);
				var dv = use(i.b);
				mov(RAX, use(i.a), size);
				var z = emit(MOVI);
				z.flag = true; // (mov: flags may be live)
				z.d = RDX;
				z.size = 4;
				var x = emit(IDIV);
				x.s1 = dv;
				x.cond = 6;
				x.size = size;
				mov(reg(i.id), i.op == UDiv ? RAX : RDX, size);
			case FAdd | FSub | FMul | FDiv:
				// commutative: a constant as the second operand (a memory
				// operand), else the operand used only here as the destination
				var a = i.a, c = i.b;
				inline function k(v:Int):Bool
					return m.vals[v].op == ConstF;
				if ((i.op == FAdd || i.op == FMul) && !k(c) && (k(a) || useCount[c] == 1 && useCount[a] > 1)) {
					a = i.b;
					c = i.a;
				}
				var d = reg(i.id);
				mov(d, use(a));
				var x = emit(k(c) ? FOPK : FOP);
				x.d = d;
				if (k(c)) x.f = m.vals[c].f else x.s1 = use(c);
				x.cond = switch i.op {
					case FAdd: 0x58;
					case FMul: 0x59;
					case FSub: 0x5c;
					case _: 0x5e;
				};
			case FSqrt:
				var x = emit(FSQRT);
				x.d = reg(i.id);
				x.s1 = use(i.a);
			case FNeg | FAbs:
				var d = reg(i.id);
				mov(d, use(i.a));
				var x = emit(FMASK);
				x.d = d;
				x.cond = i.op == FNeg ? 0x57 : 0x54;
				x.imm = i.op == FNeg ? 0 : 1;
			case Cmp:
				if (useCount[i.id] == 0) return; // unused (MirWriter.cmp folded it)
				// fused into the branch that follows
				if (fusable(i, b)) return;
				var d = reg(i.id);
				var cc = compare(i.imm, i.a, i.b);
				if (cc == -1 || cc == -2) {
					// FEq: ZF and not PF; FNe: not ZF or PF
					var t = f.newReg(false);
					setcc(d, cc == -1 ? E : NE);
					setcc(t, cc == -1 ? NP : P);
					var x = emit(ALU);
					x.d = d;
					x.s1 = t;
					x.cond = cc == -1 ? Asm.AND : Asm.OR;
					x.size = 4;
				} else {
					setcc(d, cc);
					// used elsewhere too, and branched on right after: the branch
					// reads the flags (setcc leaves them)
					var t = b.term();
					if (t != null && t.op == Br && t.a == i.id && b.ins.length >= 2 && b.ins[b.ins.length - 2] == i) flagsOf.set(i.id, cc);
				}
			case Select:
				var d = reg(i.id);
				var cond = m.vals[i.a];
				var cc:Int;
				if (selCond[cond.id]) {
					mov(d, use(i.c), 8);
					cc = compare(cond.imm, cond.a, cond.b);
					folded[cond.id] = true;
				} else {
					mov(d, use(i.c), 8);
					var x = emit(TEST);
					x.s1 = use(i.a);
					x.s2 = x.s1;
					x.size = 4;
					cc = NE;
				}
				var x = emit(CMOV);
				x.d = d;
				x.s1 = use(i.b);
				x.cond = cc;
				x.size = sz(i.ty);
			case SExt if (memFolds.exists(i.a)):
				var l = m.vals[i.a];
				var x = emit(LOAD);
				x.d = reg(i.id);
				x.size = 4;
				x.imm2 = 1; // movsxd from memory
				memOf(x, l.a, l.b, l.imm2, l.imm);
				x.mem = l.mem;
			case SExt:
				var x = emit(MOV);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.flag = true; // movsxd
				x.size = 8;
			case ZExt:
				var x = emit(MOV);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.size = 4;
				x.imm2 = 1; // zero-extends even into the same register
			case Trunc:
				mov(reg(i.id), use(i.a), 4);
			case I2F:
				var x = emit(CVTI2F);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.size = sz(m.vals[i.a].ty);
			case F2I:
				var x = emit(CVTF2I);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.size = sz(i.ty);
			case BitsToF:
				var x = emit(MOVQXR);
				x.d = reg(i.id);
				x.s1 = use(i.a);
			case FToBits:
				var x = emit(MOVQRX);
				x.d = reg(i.id);
				x.s1 = use(i.a);
			case Load:
				if (folded[i.id]) return; // a memory operand of its user
				var x = emit(LOAD);
				x.d = reg(i.id);
				x.size = i.size;
				x.flag = i.signed;
				memOf(x, i.a, i.b, i.imm2, i.imm);
				x.mem = i.mem;
			case Store:
				var imm = immOf(i.c);
				var x = emit(imm != null && !isF(i.c) ? STOREI : STORE);
				x.size = i.size;
				if (imm != null && !isF(i.c)) {
					x.imm = imm;
					x.isym = isymOf(i.c);
				} else x.s1 = use(i.c);
				memOf(x, i.a, i.b, i.imm2, i.imm);
				x.mem = i.mem;
			case Call if (i.sym != null && StringTools.startsWith(i.sym, hxmc.MirBuild.SPECIAL)):
				special(i);
			case Call:
				call(i);
			case Jmp:
				jmpIns(i, b);
			case Br:
				var t = i.targets[0], e = i.targets[1];
				var cond = m.vals[i.a];
				var cc:Int;
				if (folded[cond.id] && cond.op == Cmp) {
					cc = compare(cond.imm, cond.a, cond.b);
				} else if (flagsOf.exists(cond.id) && b.ins.length >= 2 && b.ins[b.ins.length - 2] == cond) {
					cc = flagsOf.get(cond.id);
				} else {
					var x = emit(TEST);
					x.s1 = use(i.a);
					x.s2 = x.s1;
					x.size = 4;
					cc = NE;
				}
				var lt = edgeTarget(b, t), le = edgeTarget(b, e);
				if (cc == -1) {
					// FEq: not equal or unordered -> else
					jcc(P, le);
					jcc(E, lt);
					jmp(le);
				} else if (cc == -2) {
					jcc(P, lt);
					jcc(NE, lt);
					jmp(le);
				} else if (lt == lb[t.id] && t == next) {
					// (jumps to the next block are not encoded; they keep the successors explicit)
					jcc(cc ^ 1, le);
					jmp(lt);
				} else {
					jcc(cc, lt);
					jmp(le);
				}
			case Switch:
				switchIns(i, b);
			case Ret if (i.a >= 0 && m.structRet):
				// a struct in rax-rdx and xmm0-xmm1, from its memory (whole words)
				structRet(i);
			case Ret:
				ret(i);
			case Unreachable:
				emit(UD2);
		}
	}

	// (the index zero-extended even into the same register: the table is
	// indexed with all 64 bits, and an Int's upper half may be anything, an
	// addition done by lea)
	override function jumpTable(v:Int, lo:Int, span:Int, def:LBlock, table:Vector<LBlock>) {
		var idx = f.newReg(false);
		var x = emit(MOV);
		x.d = idx;
		x.s1 = v;
		x.size = 4;
		x.imm2 = 1;
		if (lo != 0) {
			var a = emit(ALUI);
			a.d = idx;
			a.cond = Asm.SUB;
			a.imm = lo;
			a.size = 4;
		}
		var c = emit(CMPI);
		c.s1 = idx;
		c.imm = span - 1;
		c.size = 4;
		jcc(A, def);
		var base = f.newReg(false);
		var l = emit(LEATABLE);
		l.d = base;
		l.table = table;
		var j = emit(JTABLE);
		j.d = base;
		j.s1 = idx;
		j.s2 = f.newReg(false);
		j.table = table;
	}

	override function caseBranch(v:Int, c:Int, t:LBlock) {
		var x = emit(CMPI);
		x.s1 = v;
		x.imm = c;
		x.size = 4;
		jcc(E, t);
	}

	// the inline expansions of MirWriter.special: atomics (sequentially
	// consistent: loads are plain moves, stores xchg) and float32 conversions
	function special(i:MIns) {
		var name = i.sym.substr(hxmc.MirBuild.SPECIAL.length);
		inline function at(x:LIns, size:Int) {
			memOf(x, i.args[0], -1, 1, 0);
			x.size = size;
		}
		switch name {
			case "atomic_load4" | "atomic_load8":
				var x = emit(LOAD);
				x.d = reg(i.id);
				at(x, name == "atomic_load4" ? 4 : 8);
			case "atomic_store4" | "atomic_store8":
				var t = f.newReg(false);
				mov(t, use(i.args[1]), 8);
				var x = emit(XCHG);
				x.d = t;
				at(x, name == "atomic_store4" ? 4 : 8);
			case "atomic_add4" | "atomic_add8" | "atomic_xchg4" | "atomic_xchg8":
				var size = StringTools.endsWith(name, "4") ? 4 : 8;
				var d = reg(i.id);
				mov(d, use(i.args[1]), 8);
				var x = emit(StringTools.startsWith(name, "atomic_add") ? XADD : XCHG);
				x.d = d;
				at(x, size);
			case "atomic_cas4" | "atomic_cas8":
				var size = name == "atomic_cas4" ? 4 : 8;
				var nv = use(i.args[2]);
				mov(RAX, use(i.args[1]), 8);
				var x = emit(CMPXCHG);
				x.s1 = nv;
				at(x, size);
				mov(reg(i.id), RAX, size);
			case "fence":
				emit(MFENCE);
			case "f32_to_f64":
				var t = f.newReg(true);
				var x = emit(MOVDXR);
				x.d = t;
				x.s1 = use(i.args[0]);
				var c = emit(CVTSS2SD);
				c.d = reg(i.id);
				c.s1 = t;
			case "f64_to_f32":
				var t = f.newReg(true);
				var c = emit(CVTSD2SS);
				c.d = t;
				c.s1 = use(i.args[0]);
				var x = emit(MOVDRX);
				x.d = reg(i.id);
				x.s1 = t;
			// a float's bits in the low half of a float register (a C call's
			// float argument, MirBuild.cCall), and back (its float result)
			case "f32bits_to_freg":
				var x = emit(MOVDXR);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
			case "freg_to_f32bits":
				var x = emit(MOVDRX);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
			case _:
				throw new hxmc.MirBuild.Unsupported("unknown special " + i.sym);
		}
	}

	// ---- calls (IselBase.call)

	override function floatBits(d:Int, v:Int) {
		var x = emit(MOVQRX);
		x.d = d;
		x.s1 = use(v);
	}

	// ---- vectors (hxmc.simd, docs/plans/simd.md): SSE2 to SSE4.1 (with
	// SSSE3's pshufb, pabs and pmulhrsw), each operation WebAssembly's
	// (SimdOps), with its exact results: emulated where SSE's differ (float
	// min and max, conversions out of range, unsigned comparisons, byte
	// shifts)

	static final ONES = [-1, -1, -1, -1];

	inline function vtmp():Int
		return f.newVecReg();

	// d <- d op s (prefix 0x66 by default)
	function vx(opc:Int, d:Int, s:Int, p = 0x66, imm8 = -1, w = false) {
		var x = emit(VX);
		x.d = d;
		x.s1 = s;
		x.imm = opc;
		x.cond = p | (w ? 0x100 : 0);
		x.imm2 = imm8;
	}

	// d <- op s (rev: the reg field is s, as pextr and movd r32, xmm)
	function vxu(opc:Int, d:Int, s:Int, p = 0x66, imm8 = -1, w = false, rev = false) {
		var x = emit(VXU);
		x.d = d;
		x.s1 = s;
		x.imm = opc;
		x.cond = p | (w ? 0x100 : 0) | (rev ? 0x200 : 0);
		x.imm2 = imm8;
	}

	// d <- d shifted by an immediate (opc 0x0f71/72/73, /digit)
	function vxi(opc:Int, digit:Int, d:Int, n:Int) {
		var x = emit(VXI);
		x.d = d;
		x.imm = opc;
		x.cond = 0x66 | (digit << 12);
		x.imm2 = n;
	}

	// a vector constant other than zeros and ones (those take no load: pxor, pcmpeqd)
	function vconstOf(v:Int):Null<Array<Int>> {
		var i = m.vals[v];
		if (i.op != VConst || !folded[v]) return null;
		var w = [for (x in i.cases) x];
		if (w[0] == w[1] && w[1] == w[2] && w[2] == w[3] && (w[0] == 0 || w[0] == -1)) return null;
		return w;
	}

	// d <- a op b, the values a and b: b a constant is the memory operand;
	// so is a, when the operation is commutative
	function vbk(d:Int, a:Int, b:Int, opc:Int, comm:Bool, p = 0x66, imm8 = -1) {
		var k = vconstOf(b);
		if (k == null && comm && vconstOf(a) != null) {
			k = vconstOf(a);
			a = b;
		}
		if (k != null) {
			copyTo(d, a);
			vxk(opc, d, k, p, imm8);
		} else if (a == b) {
			// (a op a: on the copy alone, so that a may end at the copy and share d's register)
			copyTo(d, a);
			vx(opc, d, d, p, imm8);
		} else {
			var ra = use(a), rb = use(b);
			vbin(d, ra, rb, opc, p, imm8);
		}
	}

	// d <- d op a constant (four 32-bit words, the first lowest)
	function vxk(opc:Int, d:Int, words:Array<Int>, p = 0x66, imm8 = -1) {
		var x = emit(VXK);
		x.d = d;
		x.imm = opc;
		x.cond = p;
		x.imm2 = imm8;
		x.uses = Vector.fromArrayCopy(words);
	}

	function vconst(d:Int, words:Array<Int>) {
		var x = emit(VCONST);
		x.d = d;
		x.uses = Vector.fromArrayCopy(words);
	}

	function vcopy(d:Int, s:Int)
		mov(d, s, 16);

	// a byte splatted to four words
	static inline function bytes4(b:Int):Int {
		b &= 0xff;
		return b | (b << 8) | (b << 16) | (b << 24);
	}

	static inline function halves(h:Int):Int {
		h &= 0xffff;
		return h | (h << 16);
	}

	// d <- copy of a, then op b
	function vbin(d:Int, a:Int, b:Int, opc:Int, p = 0x66, imm8 = -1) {
		vcopy(d, a);
		vx(opc, d, b, p, imm8);
	}

	// d <- ~d
	inline function vnot(d:Int)
		vxk(0x0fef, d, ONES);

	// pcmpeq, pcmpgt, pminu, pmaxu of a width
	static function eqOp(w:Int):Int
		return w == 1 ? 0x0f74 : w == 2 ? 0x0f75 : w == 4 ? 0x0f76 : 0x0f3829;

	static function gtOp(w:Int):Int
		return w == 1 ? 0x0f64 : w == 2 ? 0x0f65 : 0x0f66;

	static function minuOp(w:Int):Int
		return w == 1 ? 0x0fda : w == 2 ? 0x0f383a : 0x0f383b;

	static function maxuOp(w:Int):Int
		return w == 1 ? 0x0fde : w == 2 ? 0x0f383e : 0x0f383f;

	// an I32 value into a fresh general register (a copy: it is changed)
	function gcopy(v:Int):Int {
		var r = f.newReg(false);
		mov(r, use(v), 4);
		return r;
	}

	function vop(i:MIns) {
		var n = SimdOps.name(i.imm);
		var w = SimdOps.width(i.imm);
		var f32 = StringTools.startsWith(n, "f32x4"), f64 = StringTools.startsWith(n, "f64x2");
		var fp = f32 ? 0 : 0x66; // packed single: no prefix; double: 0x66
		inline function A():Int
			return use(i.a);
		inline function B():Int
			return use(i.b);
		inline function D():Int
			return reg(i.id);
		var op = n.substr(n.indexOf(".") + 1);
		switch op {
			// bitwise
			case "and": vbk(D(), i.a, i.b, 0x0fdb, true);
			case "or": vbk(D(), i.a, i.b, 0x0feb, true);
			case "xor": vbk(D(), i.a, i.b, 0x0fef, true);
			case "andnot":
				// (pandn: ~d & s)
				vbin(D(), B(), A(), 0x0fdf);
			case "not":
				var d = D();
				vcopy(d, A());
				vnot(d);
			case "bitselect":
				// ((a ^ b) & c) ^ b
				var d = D(), b = B();
				vbin(d, A(), b, 0x0fef);
				vx(0x0fdb, d, use(i.c));
				vx(0x0fef, d, b);
			case "any_true":
				var x = emit(PTEST);
				x.s1 = A();
				setcc(D(), CC.NE);
			// lane-wise integer operations of one instruction
			case "add" if (!f32 && !f64): vbk(D(), i.a, i.b, w == 1 ? 0x0ffc : w == 2 ? 0x0ffd : w == 4 ? 0x0ffe : 0x0fd4, true);
			case "sub" if (!f32 && !f64): vbk(D(), i.a, i.b, w == 1 ? 0x0ff8 : w == 2 ? 0x0ff9 : w == 4 ? 0x0ffa : 0x0ffb, false);
			case "mul" if (!f32 && !f64): vbk(D(), i.a, i.b, w == 2 ? 0x0fd5 : 0x0f3840, true);
			case "add_sat_s": vbk(D(), i.a, i.b, w == 1 ? 0x0fec : 0x0fed, true);
			case "add_sat_u": vbk(D(), i.a, i.b, w == 1 ? 0x0fdc : 0x0fdd, true);
			case "sub_sat_s": vbk(D(), i.a, i.b, w == 1 ? 0x0fe8 : 0x0fe9, false);
			case "sub_sat_u": vbk(D(), i.a, i.b, w == 1 ? 0x0fd8 : 0x0fd9, false);
			case "min_s": vbk(D(), i.a, i.b, w == 1 ? 0x0f3838 : w == 2 ? 0x0fea : 0x0f3839, true);
			case "max_s": vbk(D(), i.a, i.b, w == 1 ? 0x0f383c : w == 2 ? 0x0fee : 0x0f383d, true);
			case "min_u": vbk(D(), i.a, i.b, minuOp(w), true);
			case "max_u": vbk(D(), i.a, i.b, maxuOp(w), true);
			case "avgr_u": vbk(D(), i.a, i.b, w == 1 ? 0x0fe0 : 0x0fe3, true);
			case "dot_i16x8_s": vbk(D(), i.a, i.b, 0x0ff5, true);
			case "q15mulr_sat_s":
				// pmulhrsw, but 0x8000 * 0x8000 saturates: 0x8000 there becomes 0x7fff
				var d = D(), t = vtmp();
				vbin(d, A(), B(), 0x0f380b);
				vconst(t, [halves(0x8000), halves(0x8000), halves(0x8000), halves(0x8000)]);
				vx(0x0f75, t, d);
				vx(0x0fef, d, t);
			case "narrow_i16x8_s": vbk(D(), i.a, i.b, 0x0f63, false);
			case "narrow_i16x8_u": vbk(D(), i.a, i.b, 0x0f67, false);
			case "narrow_i32x4_s": vbk(D(), i.a, i.b, 0x0f6b, false);
			case "narrow_i32x4_u": vbk(D(), i.a, i.b, 0x0f382b, false);
			case "swizzle":
				// (an index from 16 on: zero; pshufb zeroes where the top bit is set)
				var t = vtmp(), d = D();
				vcopy(t, B());
				vxk(0x0fdc, t, [bytes4(0x70), bytes4(0x70), bytes4(0x70), bytes4(0x70)]);
				vbin(d, A(), t, 0x0f3800);
			case "shuffle":
				shuffle(i);
			// comparisons
			case "eq" if (!f32 && !f64): vbk(D(), i.a, i.b, eqOp(w), true);
			case "ne" if (!f32 && !f64):
				var d = D();
				vbin(d, A(), B(), eqOp(w));
				vnot(d);
			case "gt_s": vbk(D(), i.a, i.b, gtOp(w), false);
			case "lt_s": vbin(D(), B(), A(), gtOp(w));
			case "le_s":
				var d = D();
				vbin(d, A(), B(), gtOp(w));
				vnot(d);
			case "ge_s":
				var d = D();
				vbin(d, B(), A(), gtOp(w));
				vnot(d);
			case "le_u" | "gt_u":
				// a <= b: min(a, b) == a
				var d = D(), a = A();
				vbin(d, a, B(), minuOp(w));
				vx(eqOp(w), d, a);
				if (op == "gt_u") vnot(d);
			case "ge_u" | "lt_u":
				var d = D(), a = A();
				vbin(d, a, B(), maxuOp(w));
				vx(eqOp(w), d, a);
				if (op == "lt_u") vnot(d);
			case "eq": vbk(D(), i.a, i.b, 0x0fc2, false, fp, 0);
			case "ne": vbk(D(), i.a, i.b, 0x0fc2, false, fp, 4);
			case "lt": vbk(D(), i.a, i.b, 0x0fc2, false, fp, 1);
			case "le": vbk(D(), i.a, i.b, 0x0fc2, false, fp, 2);
			case "gt": vbin(D(), B(), A(), 0x0fc2, fp, 1);
			case "ge": vbin(D(), B(), A(), 0x0fc2, fp, 2);
			// float arithmetic
			case "add": vbk(D(), i.a, i.b, 0x0f58, false, fp);
			case "sub": vbk(D(), i.a, i.b, 0x0f5c, false, fp);
			case "mul": vbk(D(), i.a, i.b, 0x0f59, false, fp);
			case "div": vbk(D(), i.a, i.b, 0x0f5e, false, fp);
			case "sqrt": vxu(0x0f51, D(), A(), fp);
			// (pmin: b < a ? b : a, minps(b, a)'s own rule)
			case "pmin": vbin(D(), B(), A(), 0x0f5d, fp);
			case "pmax": vbin(D(), B(), A(), 0x0f5f, fp);
			case "min" | "max":
				fminmax(op == "min", f64, D(), A(), B());
			case "abs" if (f32 || f64):
				var d = D();
				vcopy(d, A());
				vxk(0x0f54, d, f32 ? [0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff] : [-1, 0x7fffffff, -1, 0x7fffffff], fp);
			case "neg" if (f32 || f64):
				var d = D();
				vcopy(d, A());
				vxk(0x0f57, d, f32 ? [0x80000000, 0x80000000, 0x80000000, 0x80000000] : [0, 0x80000000, 0, 0x80000000], fp);
			case "ceil" | "floor" | "trunc" | "nearest":
				vxu(f32 ? 0x0f3a08 : 0x0f3a09, D(), A(), 0x66, op == "ceil" ? 2 : op == "floor" ? 1 : op == "trunc" ? 3 : 0);
			case "abs":
				if (w == 8) throw new hxmc.MirBuild.Unsupported("x86-64: " + n);
				vxu(w == 1 ? 0x0f381c : w == 2 ? 0x0f381d : 0x0f381e, D(), A());
			case "neg":
				var d = D();
				vconst(d, [0, 0, 0, 0]);
				vx(w == 1 ? 0x0ff8 : w == 2 ? 0x0ff9 : w == 4 ? 0x0ffa : 0x0ffb, d, A());
			// conversions
			case "convert_i32x4_s": vxu(0x0f5b, D(), A(), 0);
			case "convert_i32x4_u":
				// the low 16 bits exactly, the high ones halved (exact), doubled, added
				var d = D(), lo = vtmp(), a = A();
				vconst(lo, [0, 0, 0, 0]);
				vx(0x0f3a0e, lo, a, 0x66, 0x55); // pblendw: the low halves
				vbin(d, a, lo, 0x0ffa); // psubd: the high halves
				vxu(0x0f5b, lo, lo, 0); // cvtdq2ps
				vxi(0x0f72, 2, d, 1); // psrld 1
				vxu(0x0f5b, d, d, 0);
				vx(0x0f58, d, d, 0); // addps
				vx(0x0f58, d, lo, 0);
			case "trunc_sat_f32x4_s":
				// NaN -> 0, too large -> 0x7fffffff (cvttps2dq gives 0x80000000)
				var d = D(), t = vtmp(), a = A();
				vbin(t, a, a, 0x0fc2, 0, 0); // cmpeqps: not NaN
				vbin(d, a, t, 0x0f54, 0); // andps: NaN -> 0
				vx(0x0fef, t, d); // pxor: the top bit where d >= 0
				vxu(0x0f5b, d, d, 0xf3); // cvttps2dq
				vx(0x0fdb, t, d); // pand: >= 0 but negative now: overflow
				vxi(0x0f72, 4, t, 31); // psrad 31
				vx(0x0fef, d, t);
			case "trunc_sat_f64x2_s_zero":
				var d = D(), t = vtmp(), a = A();
				vbin(t, a, a, 0x0fc2, 0x66, 0); // cmpeqpd: not NaN
				vxk(0x0f54, t, [0xffc00000, 0x41dfffff, 0xffc00000, 0x41dfffff], 0); // andps 2147483647.0
				vbin(d, a, t, 0x0f5d, 0x66); // minpd (NaN: the second operand, 0)
				vxu(0x0fe6, d, d, 0x66); // cvttpd2dq
			case "convert_low_i32x4_s": vxu(0x0fe6, D(), A(), 0xf3); // cvtdq2pd
			case "promote_low_f32x4": vxu(0x0f5a, D(), A(), 0); // cvtps2pd
			case "demote_f64x2_zero": vxu(0x0f5a, D(), A(), 0x66); // cvtpd2ps
			case "extend_low_i8x16_s": vxu(0x0f3820, D(), A());
			case "extend_low_i8x16_u": vxu(0x0f3830, D(), A());
			case "extend_low_i16x8_s": vxu(0x0f3823, D(), A());
			case "extend_low_i16x8_u": vxu(0x0f3833, D(), A());
			case "extend_low_i32x4_s": vxu(0x0f3825, D(), A());
			case "extend_low_i32x4_u": vxu(0x0f3835, D(), A());
			case "extend_high_i8x16_s" | "extend_high_i8x16_u" | "extend_high_i16x8_s" | "extend_high_i16x8_u" | "extend_high_i32x4_s" | "extend_high_i32x4_u":
				var t = vtmp();
				vxu(0x0f70, t, A(), 0x66, 0xee); // pshufd: the high half low
				var s = StringTools.endsWith(op, "_s");
				vxu(switch op.substr(12, 5) {
					case "i8x16": s ? 0x0f3820 : 0x0f3830;
					case "i16x8": s ? 0x0f3823 : 0x0f3833;
					case _: s ? 0x0f3825 : 0x0f3835;
				}, D(), t);
			// shifts
			case "shl" | "shr_s" | "shr_u":
				vshift(i, op, w);
			// lanes
			case "splat":
				vsplat(i, w, f32, f64);
			case "extract_lane" | "extract_lane_s" | "extract_lane_u":
				vextract(i, w, f32, f64, op == "extract_lane_s");
			case "replace_lane":
				vreplace(i, w, f32, f64);
			case "bitmask":
				var d = D();
				switch w {
					case 1: vxu(0x0fd7, d, A());
					case 2:
						var t = vtmp();
						vbin(t, A(), A(), 0x0f63); // packsswb t, t
						vxu(0x0fd7, d, t);
						var x = emit(ALUI);
						x.d = d;
						x.cond = Asm.AND;
						x.imm = 0xff;
						x.size = 4;
					case 4: vxu(0x0f50, d, A(), 0);
					case _: vxu(0x0f50, d, A(), 0x66);
				}
			case "all_true":
				// no lane zero: pcmpeq with zero has no bit set
				var t = vtmp(), g = f.newReg(false);
				vconst(t, [0, 0, 0, 0]);
				vx(eqOp(w), t, A());
				vxu(0x0fd7, g, t);
				var x = emit(CMPI);
				x.s1 = g;
				x.imm = 0;
				x.size = 4;
				setcc(D(), CC.E);
			case _:
				throw new hxmc.MirBuild.Unsupported("x86-64: " + n);
		}
	}

	// wasm's min and max: NaN if either is, -0 below +0 (minps and maxps
	// return the second operand when either is NaN or both are zeros):
	// computed both ways and merged, NaN made a quiet NaN (V8's sequences)
	function fminmax(min:Bool, f64:Bool, d:Int, a:Int, b:Int) {
		var p = f64 ? 0x66 : 0, t = vtmp();
		var o = min ? 0x0f5d : 0x0f5f;
		vbin(t, b, a, o, p); // t = op(b, a)
		vbin(d, a, b, o, p); // d = op(a, b)
		if (min) {
			vx(0x0f56, t, d, p); // orps: -0 and NaN of either
			vcopy(d, t);
			vx(0x0fc2, d, t, p, 3); // cmpunord: NaN lanes
			vx(0x0f56, t, d, p); // orps
			vxi(f64 ? 0x0f73 : 0x0f72, 2, d, f64 ? 13 : 10); // psrl: clear the payload's top
			vx(0x0f55, d, t, p); // andnps: d = ~d & t
		} else {
			vx(0x0f57, d, t, p); // xorps: where they differ
			vx(0x0f56, t, d, p); // orps: NaN
			vx(0x0f5c, t, d, p); // subps: the sign of a zero
			vcopy(d, t);
			vx(0x0fc2, d, t, p, 3); // cmpunord
			vxi(f64 ? 0x0f73 : 0x0f72, 2, d, f64 ? 13 : 10);
			vx(0x0f55, d, t, p); // andnps
		}
	}

	function vshift(i:MIns, op:String, w:Int) {
		var d = reg(i.id), a = use(i.a);
		var k = m.vals[i.b].op == Const ? m.vals[i.b].imm & (w * 8 - 1) : -1;
		// (the count masked to the lane's width, in an xmm register)
		function count():Int {
			var g = gcopy(i.b);
			var x = emit(ALUI);
			x.d = g;
			x.cond = Asm.AND;
			x.imm = w * 8 - 1;
			x.size = 4;
			var c = vtmp();
			vxu(0x0f6e, c, g); // movd
			return c;
		}
		// shift of words, doublewords or quadwords: by register (opc) or immediate (row, digit)
		function sh(opc:Int, row:Int, digit:Int, d:Int, k:Int, c:Int)
			if (k >= 0) vxi(row, digit, d, k) else vx(opc, d, c);
		switch w {
			case 2 | 4 | 8 if (!(w == 8 && op == "shr_s")):
				vcopy(d, a);
				var c = k >= 0 ? -1 : count();
				var row = w == 2 ? 0x0f71 : w == 4 ? 0x0f72 : 0x0f73;
				switch op {
					case "shl": sh(w == 2 ? 0x0ff1 : w == 4 ? 0x0ff2 : 0x0ff3, row, 6, d, k, c);
					case "shr_u": sh(w == 2 ? 0x0fd1 : w == 4 ? 0x0fd2 : 0x0fd3, row, 2, d, k, c);
					case _: sh(w == 2 ? 0x0fe1 : 0x0fe2, row, 4, d, k, c);
				}
			case 8:
				// arithmetic: the sign of each quadword, then (a ^ s) >> n ^ s
				var s = vtmp();
				vxu(0x0f70, s, a, 0x66, 0xf5); // pshufd: each lane's high word twice
				vxi(0x0f72, 4, s, 31); // psrad 31
				vbin(d, a, s, 0x0fef);
				if (k >= 0) vxi(0x0f73, 2, d, k) else vx(0x0fd3, d, count());
				vx(0x0fef, d, s);
			case _:
				// bytes: as words, then masked (shl, shr_u) or from both halves (shr_s)
				if (op == "shr_s") {
					var hi = vtmp();
					vbin(d, a, a, 0x0f60); // punpcklbw a, a: each byte in a word's high byte
					vbin(hi, a, a, 0x0f68); // punpckhbw
					var c = -1;
					if (k >= 0) {
						vxi(0x0f71, 4, d, k + 8);
						vxi(0x0f71, 4, hi, k + 8);
					} else {
						var g = gcopy(i.b);
						var x = emit(ALUI);
						x.d = g;
						x.cond = Asm.AND;
						x.imm = 7;
						x.size = 4;
						var y = emit(ALUI);
						y.d = g;
						y.cond = Asm.ADD;
						y.imm = 8;
						y.size = 4;
						c = vtmp();
						vxu(0x0f6e, c, g);
						vx(0x0fe1, d, c);
						vx(0x0fe1, hi, c);
					}
					vx(0x0f63, d, hi); // packsswb
					return;
				}
				vcopy(d, a);
				var shl = op == "shl";
				if (k >= 0) {
					vxi(0x0f71, shl ? 6 : 2, d, k);
					var mb = shl ? (0xff << k) & 0xff : 0xff >> k;
					vxk(0x0fdb, d, [bytes4(mb), bytes4(mb), bytes4(mb), bytes4(mb)]);
				} else {
					// each half widened to words, shifted, masked to bytes, packed
					var c = count(), z = vtmp(), hi = vtmp();
					vconst(z, [0, 0, 0, 0]);
					vcopy(hi, a);
					vx(0x0f60, d, z); // punpcklbw: the low bytes, zero-extended
					vx(0x0f68, hi, z); // punpckhbw
					vx(shl ? 0x0ff1 : 0x0fd1, d, c);
					vx(shl ? 0x0ff1 : 0x0fd1, hi, c);
					if (shl) {
						var k8 = [halves(0xff), halves(0xff), halves(0xff), halves(0xff)];
						vxk(0x0fdb, d, k8);
						vxk(0x0fdb, hi, k8);
					}
					vx(0x0f67, d, hi); // packuswb
				}
		}
	}

	function vsplat(i:MIns, w:Int, f32:Bool, f64:Bool) {
		var d = reg(i.id);
		if (f32) {
			vxu(0x0f5a, d, use(i.a), 0xf2); // cvtsd2ss
			vx(0x0fc6, d, d, 0, 0); // shufps 0
			return;
		}
		if (f64) {
			vcopy(d, use(i.a));
			vx(0x0f14, d, d, 0x66); // unpcklpd
			return;
		}
		vxu(0x0f6e, d, use(i.a), 0x66, -1, w == 8); // movd / movq
		switch w {
			case 1:
				var z = vtmp();
				vconst(z, [0, 0, 0, 0]);
				vx(0x0f3800, d, z); // pshufb with zeros: byte 0 everywhere
			case 2:
				vxu(0x0f70, d, d, 0xf2, 0); // pshuflw 0
				vxu(0x0f70, d, d, 0x66, 0); // pshufd 0
			case 4: vxu(0x0f70, d, d, 0x66, 0);
			case _: vx(0x0f6c, d, d); // punpcklqdq
		}
	}

	function vextract(i:MIns, w:Int, f32:Bool, f64:Bool, signed:Bool) {
		var d = reg(i.id), a = use(i.a), l = i.imm2;
		if (f32) {
			if (l == 0) vxu(0x0f5a, d, a, 0xf3) else {
				var t = vtmp();
				vxu(0x0f70, t, a, 0x66, l); // pshufd: lane l low
				vxu(0x0f5a, d, t, 0xf3); // cvtss2sd
			}
			return;
		}
		if (f64) {
			if (l == 0) mov(d, a, 16) else vxu(0x0f70, d, a, 0x66, 0xee);
			return;
		}
		switch w {
			case 1: vxu(0x0f3a14, d, a, 0x66, l, false, true); // pextrb
			case 2: vxu(0x0fc5, d, a, 0x66, l); // pextrw
			case 4: if (l == 0) vxu(0x0f7e, d, a, 0x66, -1, false, true) else vxu(0x0f3a16, d, a, 0x66, l, false, true);
			case _: if (l == 0) vxu(0x0f7e, d, a, 0x66, -1, true, true) else vxu(0x0f3a16, d, a, 0x66, l, true, true);
		}
		if (signed && w < 4) {
			var x = emit(SHIFTI);
			x.d = d;
			x.cond = Asm.SHL;
			x.imm = 32 - 8 * w;
			x.size = 4;
			var y = emit(SHIFTI);
			y.d = d;
			y.cond = Asm.SAR;
			y.imm = 32 - 8 * w;
			y.size = 4;
		}
	}

	function vreplace(i:MIns, w:Int, f32:Bool, f64:Bool) {
		var d = reg(i.id), l = i.imm2;
		if (f32) {
			var t = vtmp();
			vxu(0x0f5a, t, use(i.b), 0xf2); // cvtsd2ss
			vcopy(d, use(i.a));
			vx(0x0f3a21, d, t, 0x66, l << 4); // insertps
			return;
		}
		if (f64) {
			var x = use(i.b);
			vcopy(d, use(i.a));
			if (l == 0) vx(0x0f10, d, x, 0xf2) else vx(0x0f14, d, x, 0x66); // movsd (the low half) / unpcklpd
			return;
		}
		vcopy(d, use(i.a));
		var s = use(i.b);
		switch w {
			case 1: vx(0x0f3a20, d, s, 0x66, l); // pinsrb
			case 2: vx(0x0fc4, d, s, 0x66, l); // pinsrw
			case 4: vx(0x0f3a22, d, s, 0x66, l); // pinsrd
			case _: vx(0x0f3a22, d, s, 0x66, l, true); // pinsrq
		}
	}

	// the shuffle's lanes as elements of g bytes (lane k*g + j is lane
	// k*g's + j, at a multiple of g), else null
	static function elements(ls:Vector<Int>, g:Int):Null<Array<Int>> {
		var e = [];
		for (k in 0...Std.int(16 / g)) {
			var l = ls[k * g];
			if (l % g != 0) return null;
			for (j in 1...g)
				if (ls[k * g + j] != l + j) return null;
			e.push(Std.int(l / g));
		}
		return e;
	}

	// whether elements e (n of them; n and up: the second vector's) are the
	// low (hi false) or high halves of x and y interleaved, x the first
	// vector or the second (swap)
	static function isUnpack(e:Array<Int>, hi:Bool, swap:Bool):Bool {
		var n = e.length, h = n >> 1;
		for (k in 0...h) {
			var x = (hi ? h : 0) + k;
			if (e[2 * k] != (swap ? x + n : x) || e[2 * k + 1] != (swap ? x : x + n)) return false;
		}
		return true;
	}

	// a shuffle that is one instruction: an unpack (punpckl/h of bytes,
	// words, doublewords or quadwords; the second operand a memory one when
	// it is a constant), a pshufd of one vector, or a pshufb of one vector
	// and zeros (index 0x80: a zero byte)
	function shuffle1(i:MIns, d:Int):Bool {
		var ls = i.cases;
		for (g in [1, 2, 4, 8]) {
			var e = elements(ls, g);
			if (e == null) continue;
			var row = g == 1 ? 0 : g == 2 ? 1 : g == 4 ? 2 : 3;
			for (hi in [false, true])
				for (swap in [false, true])
					if (isUnpack(e, hi, swap)) {
						var opc = g == 8 ? (hi ? 0x0f6d : 0x0f6c) : (hi ? 0x0f68 : 0x0f60) + row;
						vbk(d, swap ? i.b : i.a, swap ? i.a : i.b, opc, false);
						return true;
					}
			if (g == 4) {
				// one vector's doublewords
				var fromB = e[0] >= 4, ok = true, imm = 0;
				for (k in 0...4) {
					if ((e[k] >= 4) != fromB) ok = false;
					imm |= (e[k] & 3) << (2 * k);
				}
				if (ok) {
					var r = use(fromB ? i.b : i.a);
					vxu(0x0f70, d, r, 0x66, imm);
					return true;
				}
			}
		}
		// a's bytes and zeros of a zero vector b (or the reverse)
		for (zb in [true, false]) {
			var z = m.vals[zb ? i.b : i.a];
			if (z.op != VConst || z.cases[0] != 0 || z.cases[1] != 0 || z.cases[2] != 0 || z.cases[3] != 0) continue;
			var w = [0, 0, 0, 0];
			for (k in 0...16) {
				var l = ls[k];
				var fromZero = (l >= 16) == zb;
				w[k >> 2] |= (fromZero ? 0x80 : l & 15) << (8 * (k & 3));
			}
			copyTo(d, zb ? i.a : i.b);
			vxk(0x0f3800, d, w);
			return true;
		}
		return false;
	}

	// pshufb from a (lanes below 16) and b (16 and up), or'ed
	function shuffle(i:MIns) {
		var d = reg(i.id);
		if (shuffle1(i, d)) return;
		var ls = i.cases;
		function mask(fromB:Bool):Array<Int> {
			var w = [0, 0, 0, 0];
			for (k in 0...16) {
				var l = ls[k];
				var byte = (l >= 16) == fromB ? l & 15 : 0x80;
				w[k >> 2] |= byte << (8 * (k & 3));
			}
			return w;
		}
		var anyA = false, anyB = false;
		for (l in ls)
			if (l < 16) anyA = true else anyB = true;
		if (anyA) {
			vcopy(d, use(i.a));
			vxk(0x0f3800, d, mask(false));
		}
		if (anyB) {
			var t = anyA ? vtmp() : d;
			vcopy(t, use(i.b));
			vxk(0x0f3800, t, mask(true));
			if (anyA) vx(0x0feb, d, t);
		}
	}

	// (a float comparison is a value: cmov reads its flags as a parity test too)
	override function selectFolds(c:MIns):Bool
		return m.vals[c.a].ty != F64;

	override function f32FromBits(d:Int, s:Int) {
		var x = emit(MOVDXR);
		x.d = d;
		x.s1 = s;
	}

	override function stackArg(i:MIns, k:Int, loc:ArgLoc) {
		var a = i.args[k];
		var t = i.argTys[k];
		var imm = immOf(a);
		var x = emit(imm != null && t != F64 ? STOREI : STORE);
		x.base = -4; // outgoing argument area
		x.disp = loc.off;
		x.size = 8;
		if (imm != null && t != F64) {
			x.imm = imm;
			x.isym = isymOf(a);
		} else x.s1 = use(a);
	}

	override function beforeCall(i:MIns, uses:Array<Int>) {
		if (i.variadic >= 0 && !win) {
			// System V: al bounds the vector registers a variadic call passes
			var nv = 0;
			for (u in uses)
				if (u >= XMM0) nv++;
			var r = emit(MOVI);
			r.flag = true;
			r.d = RAX;
			r.imm = nv;
			r.size = 4;
			uses.push(RAX);
		}
	}

	// (a struct in rax-rdx and xmm0-xmm1: whole words, the slot is rounded up to them)
	override function loadPart(r:Int, addr:Int, p:CPart) {
		var l = emit(LOAD);
		l.d = r;
		l.size = p.size == 16 ? 16 : 8;
		memOf(l, addr, -1, 1, p.off);
	}

	override function takePart(r:Int, p:CPart):Int {
		var t = p.size == 16 ? f.newVecReg() : f.newReg(p.float);
		mov(t, r, 8);
		return t;
	}

	override function storePart(r:Int, addr:Int, p:CPart) {
		var s = emit(STORE);
		s.size = p.size == 16 ? 16 : 8;
		s.s1 = r;
		memOf(s, addr, -1, 1, p.off);
	}
}
