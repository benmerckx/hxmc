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
	var IDIV; // rax, rdx <- rdx:rax / s1
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

	// whether load v is a memory operand of its user (marks it folded)
	function memFold(v:Int):Bool {
		return memFolds.exists(v);
	}

	public function new(abi:Abi) {
		super(abi);
		win = abi.os == "windows";
		if (win) gprs = abi.framePointers ? WIN_GPRS_FP : WIN_GPRS else gprs = abi.framePointers ? GPRS_FP : GPRS;
		fprs = FPRS;
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
		for (b in mf.blocks)
			for (i in b.ins)
				if ((i.op == Load || i.op == Store) && i.imm > -0x40000000 && i.imm < 0x40000000) addrUses[i.a]++;
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
				if (c == null || c <= -0x40000000 || c >= 0x40000000 || folded[i.a] && mf.vals[i.a].op == Const) continue;
				folded[i.id] = true;
			}
		// constants and symbol addresses used once by a foldable user are not computed on their own
		for (b in mf.blocks)
			for (i in b.ins)
				if ((i.op == Const && immOf(i.id) != null) || i.op == SymAddr || i.op == StackAddr || i.op == ConstF) folded[i.id] = true;
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
		if (folded[base] && bi.op == Add) {
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
				AnonTest | AnonStore | AnonCall | ArrayLength | ArrayGet | ArraySet | ArrayPush | NewArray | ArrayInit | NewNArray | NArrayInit | NArrayLength | NArrayView |
				NArrayGet | NArraySet | NArrayDyn | RefStore | IrNode | VarGet | VarSet | Try | Catch:
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
				if (cond.op == Cmp && useCount[cond.id] == 1 && cond.block == b && m.vals[cond.a].ty != F64) {
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
		l.size = 8;
		memOf(l, addr, -1, 1, p.off);
	}

	override function takePart(r:Int, p:CPart):Int {
		var t = f.newReg(p.float);
		mov(t, r, 8);
		return t;
	}

	override function storePart(r:Int, addr:Int, p:CPart) {
		var s = emit(STORE);
		s.size = 8;
		s.s1 = r;
		memOf(s, addr, -1, 1, p.off);
	}
}
