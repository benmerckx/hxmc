package hxmc.a64;

import hxmc.Mir;
import hxmc.Abi;
import hxmc.Lir;
import hxmc.CallConv.ArgLoc;
import hxmc.CAbi.CPart;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// AArch64 LIR operations (LIns.op)
enum abstract AOp(Int) to Int from Int {
	var MOV; // d <- s1 (size 4: a 32-bit move, zero-extending)
	var MOVI; // d <- imm (imm2: high half), or the absolute symbol isym + imm
	var MOVF; // d (fpr) <- f
	var LEA; // d <- address (sym, frame slot, base + disp)
	var LOAD; // d <- [mem] (size; flag: sign-extend)
	var STORE; // [mem] <- s1 (31: the zero register)
	var ALU; // d <- s1 (cond: 0 add, 1 sub, 2 and, 3 orr, 4 eor) s2
	var ALUI; // d <- s1 op imm
	var ADDSH; // d <- s1 + (s2 << imm)
	var MUL;
	var SDIV; // d <- s1 / s2 (flag: udiv)
	var MSUB; // d <- s3 - s1 * s2
	var SHIFT; // d <- s1 (cond: 2 lsl, 3 lsr, 4 asr) s2
	var SHIFTI; // d <- s1 op imm
	var NEG;
	var MVN;
	var SXTW;
	var CMP; // flags <- s1 - s2
	var CMPI; // flags <- s1 - imm (or the symbol isym)
	var FCMP;
	var CSET; // d <- cond
	var CSEL; // d <- cond ? s1 : s2
	var FOP2; // d <- s1 (cond: 0 fmul, 1 fdiv, 2 fadd, 3 fsub) s2
	var FOP1; // d <- (cond: 1 fabs, 2 fneg, 3 fsqrt, 4 frintm, 5 frintp) s1
	var SCVTF; // d (fpr) <- s1 (size)
	var FCVTZS; // d <- s1 (fpr), truncating (size)
	var FMOVTOG; // d <- bits of s1 (fpr)
	var FMOVFROMG; // d (fpr) <- bits of s1
	var CALL; // sym, or s1; uses: argument registers
	var RET;
	var B; // target
	var BCOND; // cond -> target
	var CBZ; // s1 == 0 -> target (flag: cbnz); size
	var JTABLE; // s1: index (in range), table
	var TLSLOAD; // d <- thread-local sym (s2 >= 0: at its offset from the TLS base s2)
	var TLSSTORE; // thread-local sym <- s1 (s2: as TLSLOAD)
	var TEBLOAD; // d <- [x18 + imm] (Windows: the thread environment block)
	var BRK;
	// (hxmc.unsafe: MirBuild.intrinsic)
	var LDAR; // d <- [s1], acquire (size)
	var STLR; // [s1] <- s2, release (size)
	var ATOMIC; // d <- old [s1]; cond 0: [s1] += s2, 1: [s1] = s2, 2: [s1] = s2 if old == s3 (ldaxr/stlxr loop over x16/x17)
	var KEEP; // no code: s1, s2, s3 live to here (ATOMIC's operands outlive its result)
	var DMB; // cond 0: dmb ish, 1: dmb ishst
	var FMOVSW; // d (fpr, single) <- s1 (32 bits)
	var FMOVWS; // d (32 bits) <- s1 (fpr, single)
	var FCVTSD; // d (double) <- s1 (single)
	var FCVTDS; // d (single) <- s1 (double)
	// vectors (hxmc.simd, docs/plans/simd.md): one NEON instruction, imm its
	// encoding with zero register fields; Rd d, Rn s1, Rm s2 (any class);
	// flag: Rd is read too (bsl, ins, sqxtn2)
	var NV;
	var VCONST; // d <- the constant of uses (four 32-bit words), through x16
}

// Mir -> LIR for AArch64 (AAPCS64 and its Apple and Windows variants:
// CallConv); the walk, the edges, switches and calls are IselBase's. x16/x17
// are the emitter's scratch registers and x18 is the platform register: none
// of them is allocated.
class Isel extends hxmc.IselBase implements hxmc.Target.Selector {
	public static inline var ZR = 31;

	// the allocatable registers in order of preference
	static final GPRS:Vector<Int> = vector(9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28);
	static final FPRS:Vector<Int> = vector(32, 33, 34, 35, 36, 37, 38, 39, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 40, 41, 42, 43,
		44, 45, 46, 47);
	// (vectors: not v8-v15, whose upper halves a call does not keep, AAPCS64)
	static final VPRS:Vector<Int> = vector(32, 33, 34, 35, 36, 37, 38, 39, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63);

	var apple:Bool;

	public function new(abi:Abi) {
		super(abi);
		apple = abi.os == "macos";
		gprs = GPRS;
		fprs = FPRS;
		vprs = VPRS;
		fprBase = 32;
		opMov = MOV;
		opLoad = LOAD;
		opStore = STORE;
		opJmp = B;
		opCall = CALL;
		opRet = RET;
		opTeb = TEBLOAD;
	}

	// ---- RegTarget

	public function defsUses(i:LIns, defs:hxmc.Regalloc.RegList, uses:hxmc.Regalloc.RegList) {
		inline function u(r:Int)
			if (r >= 0 && r != ZR) uses.push(r);
		inline function mem() {
			if (i.base >= 0) u(i.base);
			if (i.index >= 0) u(i.index);
		}
		switch (i.op : AOp) {
			case NV:
				defs.push(i.d);
				if (i.flag) uses.push(i.d);
				if (i.s1 >= 0) uses.push(i.s1);
				if (i.s2 >= 0) uses.push(i.s2);
			case VCONST:
				defs.push(i.d);
			case MOV | NEG | MVN | SXTW | FOP1 | SCVTF | FCVTZS | FMOVTOG | FMOVFROMG | SHIFTI | ALUI | FMOVSW | FMOVWS | FCVTSD | FCVTDS | LDAR:
				defs.push(i.d);
				u(i.s1);
			case STLR:
				u(i.s1);
				u(i.s2);
			case ATOMIC:
				defs.push(i.d);
				u(i.s1);
				u(i.s2);
				u(i.s3);
			case KEEP:
				u(i.s1);
				u(i.s2);
				u(i.s3);
			case DMB:
			case MOVI | MOVF | CSET | TLSLOAD | TEBLOAD:
				defs.push(i.d);
				u(i.s2);
			case LEA | LOAD:
				defs.push(i.d);
				mem();
			case STORE:
				u(i.s1);
				mem();
			case ALU | ADDSH | MUL | SDIV | SHIFT | FOP2 | CSEL:
				defs.push(i.d);
				u(i.s1);
				u(i.s2);
			case MSUB:
				defs.push(i.d);
				u(i.s1);
				u(i.s2);
				u(i.s3);
			case CMP | FCMP:
				u(i.s1);
				u(i.s2);
			case CMPI | CBZ | JTABLE | TLSSTORE:
				u(i.s1);
				u(i.s2);
			case CALL:
				if (i.s1 >= 0) uses.push(i.s1);
				for (x in i.uses)
					uses.push(x);
				for (r in cc.callerSaved)
					defs.push(r);
			case RET:
				for (x in i.uses)
					uses.push(x);
			case B | BCOND | BRK:
		}
	}

	public function isBranch(i:LIns):Bool
		return i.op == B || i.op == BCOND || i.op == CBZ || i.op == JTABLE || i.op == BRK;

	// ---- selection

	// an operand where the zero register can stand for 0 (store values, the
	// second operand of register operations, csel)
	function useZ(v:Int):Int {
		var i = m.vals[v];
		if (folded[v] && i.op == Const && i.sym == null && i.imm == 0 && (i.ty == I32 || i.imm2 == 0)) return ZR;
		return use(v);
	}

	// a plain constant that fits in 32 bits (sign-extended for 64-bit values)
	function immOf(v:Int):Null<Int> {
		var i = m.vals[v];
		if (i.op != Const || i.sym != null) return null;
		if (i.ty == I32) return i.imm;
		if (i.imm2 == (i.imm < 0 ? -1 : 0)) return i.imm;
		return null;
	}

	static inline function addImm(v:Int):Bool
		return v >= -4095 && v <= 4095;

	// constants and addresses are materialized where they are used
	override function prepare() {
		for (b in m.blocks)
			for (i in b.ins)
				if (i.op == Const || i.op == SymAddr || i.op == StackAddr) folded[i.id] = true;
	}

	override function materialize(i:MIns, r:Int) {
		if (r < LFunc.NPHYS) flush();
		switch i.op {
			case Const:
				var x = new LIns(MOVI);
				push(x);
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
			case _:
				throw "hxmc: cannot materialize " + MFunc.opName(i.op);
		}
	}

	// base + index * scale + disp; the emitter handles what an instruction cannot encode
	function memOf(x:LIns, base:Int, index:Int, scale:Int, disp:Int, size:Int) {
		var bi = m.vals[base];
		x.disp = disp;
		x.scale = scale;
		if (folded[base] && bi.op == SymAddr && index < 0) {
			x.sym = bi.sym;
			x.disp += bi.imm;
			return;
		}
		if (folded[base] && bi.op == StackAddr && index < 0) {
			x.base = LIns.FRAME;
			x.slot = bi.imm;
			return;
		}
		var b = use(base);
		if (index >= 0) {
			var ix = use(index);
			// [b + ix << log2(size)] or [b + ix] encode directly
			if (disp == 0 && (scale == size || scale == 1)) {
				x.base = b;
				x.index = ix;
				return;
			}
			var t = f.newReg(false);
			var a = new LIns(ADDSH);
			push(a);
			a.d = t;
			a.s1 = b;
			a.s2 = ix;
			a.imm = scale == 8 ? 3 : scale == 4 ? 2 : scale == 2 ? 1 : 0;
			x.base = t;
			x.scale = 1;
			return;
		}
		x.base = b;
	}

	function bcond(c:Int, t:LBlock) {
		var x = emit(BCOND);
		x.cond = c;
		x.target = t;
	}

	static function cond(c:Int):Int
		return switch (c : Cond) {
			case CEq | FEq: Asm.EQ;
			case CNe | FNe: Asm.NE;
			case CLt: Asm.LT;
			case CLe: Asm.LE;
			case CGt: Asm.GT;
			case CGe: Asm.GE;
			case CULt: Asm.LO;
			case CULe: Asm.LS;
			case CUGt: Asm.HI;
			case CUGe: Asm.HS;
			case FLt: Asm.MI;
			case FLe: Asm.LS;
			case FGt: Asm.GT;
			case FGe: Asm.GE;
		};

	// sets the flags; returns the AArch64 condition
	function compare(c:Int, a:Int, b:Int):Int {
		var t = m.vals[a].ty;
		if (t == F64) {
			var x = emit(FCMP);
			x.s1 = use(a);
			x.s2 = use(b);
			return cond(c);
		}
		var ib = immOf(b);
		if (ib != null && addImm(ib)) {
			var x = emit(CMPI);
			x.s1 = use(a);
			x.imm = ib;
			x.size = sz(t);
			return cond(c);
		}
		var ia = immOf(a);
		if (ia != null && addImm(ia)) {
			var x = emit(CMPI);
			x.s1 = use(b);
			x.imm = ia;
			x.size = sz(t);
			return cond(swapCond(c));
		}
		var x = emit(CMP);
		x.s1 = use(a);
		x.s2 = use(b);
		x.size = sz(t);
		return cond(c);
	}

	function aluOp(op:Op):Int
		return switch op {
			case Add: 0;
			case Sub: 1;
			case And: 2;
			case Or: 3;
			case _: 4;
		};

	override function ins(i:MIns, b:MBlock, next:Null<MBlock>) {
		switch i.op {
			case VOp:
				vop(i);
			case VConst:
				vconst(reg(i.id), [for (w in i.cases) w]);
			case Phi | Const | SymAddr | StackAddr:
			case Param:
				param(i);
			case ConstF:
				var x = emit(MOVF);
				x.d = reg(i.id);
				x.f = i.f;
			case TlsLoad | TlsStore if (abi.tls != LocalExec && tlsBase < 0):
				throw new hxmc.MirBuild.Unsupported("thread-local variables: TLS model " + abi.tls);
			case TlsLoad:
				var x = emit(TLSLOAD);
				x.d = reg(i.id);
				x.sym = i.sym;
				x.s2 = tlsBase;
			case TlsStore:
				var v = use(i.a);
				var x = emit(TLSSTORE);
				x.s1 = v;
				x.sym = i.sym;
				x.s2 = tlsBase;
			case Copy:
				mov(reg(i.id), use(i.a));
			case Add | Sub | And | Or | Xor:
				var size = sz(i.ty);
				var imm = immOf(i.b);
				var op = aluOp(i.op);
				if (imm != null && (op <= 1 && addImm(imm) || op >= 2 && Asm.bitmask(imm, imm < 0 ? -1 : 0, size == 8) >= 0)) {
					var x = emit(ALUI);
					x.d = reg(i.id);
					x.s1 = use(i.a);
					x.cond = op;
					x.imm = imm;
					x.size = size;
					return;
				}
				var ia = immOf(i.a);
				if (ia != null && op != 1 && (op == 0 && addImm(ia) || op >= 2 && Asm.bitmask(ia, ia < 0 ? -1 : 0, size == 8) >= 0)) {
					var x = emit(ALUI);
					x.d = reg(i.id);
					x.s1 = use(i.b);
					x.cond = op;
					x.imm = ia;
					x.size = size;
					return;
				}
				var x = emit(ALU);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.s2 = useZ(i.b);
				x.cond = op;
				x.size = size;
			case Mul:
				var imm = immOf(i.b);
				if (imm != null && imm > 1 && imm & (imm - 1) == 0) {
					// by a power of two: a shift
					var k = 0;
					while (imm > 1) {
						imm >>>= 1;
						k++;
					}
					var x = emit(SHIFTI);
					x.d = reg(i.id);
					x.s1 = use(i.a);
					x.cond = 2;
					x.imm = k;
					x.size = sz(i.ty);
				} else {
					var x = emit(MUL);
					x.d = reg(i.id);
					x.s1 = use(i.a);
					x.s2 = use(i.b);
					x.size = sz(i.ty);
				}
			case Div | UDiv:
				var x = emit(SDIV);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.s2 = use(i.b);
				x.flag = i.op == UDiv;
				x.size = sz(i.ty);
			case Rem | URem:
				var a = use(i.a), bb = use(i.b);
				var q = f.newReg(false);
				var x = emit(SDIV);
				x.flag = i.op == URem;
				x.d = q;
				x.s1 = a;
				x.s2 = bb;
				x.size = sz(i.ty);
				var y = emit(MSUB);
				y.d = reg(i.id);
				y.s1 = q;
				y.s2 = bb;
				y.s3 = a;
				y.size = sz(i.ty);
			case Shl | Sar | Shr:
				var size = sz(i.ty);
				var o = i.op == Shl ? 2 : i.op == Shr ? 3 : 4;
				var imm = immOf(i.b);
				if (imm != null) {
					var x = emit(SHIFTI);
					x.d = reg(i.id);
					x.s1 = use(i.a);
					x.cond = o;
					x.imm = imm & (size == 8 ? 63 : 31);
					x.size = size;
				} else {
					var x = emit(SHIFT);
					x.d = reg(i.id);
					x.s1 = use(i.a);
					x.s2 = use(i.b);
					x.cond = o;
					x.size = size;
				}
			case NullCheck | New | NewDyn | InitField | GetField | SetField | FieldAddr | EnumTag | TypeTest | Box | Unbox | VirtualCall | ClosureCall | AnonGet |
				AnonTest | AnonStore | AnonCall | ArrayLength | ArrayGet | ArraySet | ArrayPush | NewArray | ArrayInit | NewNArray | NArrayInit | NArrayLength |
				NArrayGet | NArraySet | NArrayDyn | RefStore | Tag | Untag:
				objectLevel(i);
			case Rotr:
				var x = emit(SHIFTI);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.cond = 5;
				x.imm = m.vals[i.b].imm & (sz(i.ty) == 8 ? 63 : 31);
				x.size = sz(i.ty);
			case Neg | Not:
				var x = emit(i.op == Neg ? NEG : MVN);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.size = sz(i.ty);
			case FAdd | FSub | FMul | FDiv:
				var x = emit(FOP2);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.s2 = use(i.b);
				x.cond = switch i.op {
					case FMul: 0;
					case FDiv: 1;
					case FAdd: 2;
					case _: 3;
				};
			case FSqrt | FNeg | FAbs:
				var x = emit(FOP1);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.cond = i.op == FAbs ? 1 : i.op == FNeg ? 2 : 3;
			case Cmp:
				if (useCount[i.id] == 0) return; // unused (MirWriter.cmp folded it)
				if (fusable(i, b)) return;
				var cc = compare(i.imm, i.a, i.b);
				var x = emit(CSET);
				x.d = reg(i.id);
				x.cond = cc;
			case Select:
				var cv = m.vals[i.a];
				var cc:Int;
				if (selCond[cv.id]) {
					cc = compare(cv.imm, cv.a, cv.b);
				} else {
					var x = emit(CMPI);
					x.s1 = use(i.a);
					x.imm = 0;
					x.size = 4;
					cc = Asm.NE;
				}
				var x = emit(CSEL);
				x.d = reg(i.id);
				x.s1 = useZ(i.b);
				x.s2 = useZ(i.c);
				x.cond = cc;
				x.size = sz(i.ty);
			case SExt:
				var x = emit(SXTW);
				x.d = reg(i.id);
				x.s1 = use(i.a);
			case ZExt | Trunc:
				mov(reg(i.id), use(i.a), 4);
			case I2F:
				var x = emit(SCVTF);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.size = sz(m.vals[i.a].ty);
			case F2I:
				var x = emit(FCVTZS);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.size = sz(i.ty);
			case BitsToF:
				var x = emit(FMOVFROMG);
				x.d = reg(i.id);
				x.s1 = use(i.a);
			case FToBits:
				var x = emit(FMOVTOG);
				x.d = reg(i.id);
				x.s1 = use(i.a);
			case Load:
				var x = emit(LOAD);
				x.d = reg(i.id);
				x.size = i.size;
				x.flag = i.signed;
				memOf(x, i.a, i.b, i.imm2, i.imm, i.size);
			case Store:
				// a store that publishes a reference: the stores before it first
				// (dmb ishst; the reader's loads through it are ordered by their
				// address dependency)
				if (i.release) emit(DMB).cond = 1;
				var x = emit(STORE);
				x.size = i.size;
				x.s1 = useZ(i.c);
				memOf(x, i.a, i.b, i.imm2, i.imm, i.size);
			case Call if (i.sym != null && StringTools.startsWith(i.sym, hxmc.MirBuild.SPECIAL)):
				special(i);
			case Call:
				call(i);
			case Jmp:
				jmpIns(i, b);
			case Br:
				var t = i.targets[0], e = i.targets[1];
				var cv = m.vals[i.a];
				var lt:LBlock, le:LBlock;
				if (folded[cv.id] && cv.op == Cmp) {
					var cc = compare(cv.imm, cv.a, cv.b);
					lt = edgeTarget(b, t);
					le = edgeTarget(b, e);
					// unordered compares: FNe is true, the others false, as NE/MI/LS/GT/GE/EQ give
					bcond(cc, lt);
				} else {
					var r = use(i.a);
					lt = edgeTarget(b, t);
					le = edgeTarget(b, e);
					var x = emit(CBZ);
					x.s1 = r;
					x.flag = true;
					x.size = 4;
					x.target = lt;
				}
				jmp(le);
			case Switch:
				switchIns(i, b);
			case Ret if (i.a >= 0 && m.structRet):
				// a struct in x0-x1 or d0-d3 (s0-s3), from its memory
				structRet(i);
			case Ret:
				ret(i);
			case Unreachable:
				emit(BRK);
		}
	}

	override function jumpTable(v:Int, lo:Int, span:Int, def:LBlock, table:Vector<LBlock>) {
		var idx = f.newReg(false);
		if (lo != 0) {
			if (addImm(lo)) {
				var a = emit(ALUI);
				a.d = idx;
				a.s1 = v;
				a.cond = 1;
				a.imm = lo;
				a.size = 4;
			} else {
				var k = f.newReg(false);
				var mi = emit(MOVI);
				mi.d = k;
				mi.imm = lo;
				mi.size = 4;
				var a = emit(ALU);
				a.d = idx;
				a.s1 = v;
				a.s2 = k;
				a.cond = 1;
				a.size = 4;
			}
		} else mov(idx, v, 4);
		var c = emit(CMPI);
		c.s1 = idx;
		c.imm = span - 1;
		c.size = 4;
		if (span - 1 > 4095) {
			var k = f.newReg(false);
			pending = null;
			var mi = emit(MOVI);
			mi.d = k;
			mi.imm = span - 1;
			mi.size = 4;
			var cr = emit(CMP);
			cr.s1 = idx;
			cr.s2 = k;
			cr.size = 4;
		}
		bcond(Asm.HI, def);
		var j = emit(JTABLE);
		j.s1 = idx;
		j.table = table;
	}

	override function caseBranch(v:Int, c:Int, t:LBlock) {
		if (addImm(c)) {
			var x = emit(CMPI);
			x.s1 = v;
			x.imm = c;
			x.size = 4;
		} else {
			var k = f.newReg(false);
			var mi = emit(MOVI);
			mi.d = k;
			mi.imm = c;
			mi.size = 4;
			var x = emit(CMP);
			x.s1 = v;
			x.s2 = k;
			x.size = 4;
		}
		bcond(Asm.EQ, t);
	}

	// the inline expansions of MirWriter.special: atomics (sequentially
	// consistent: ldar, stlr, ldaxr/stlxr loops) and float32 conversions
	function special(i:MIns) {
		var name = i.sym.substr(hxmc.MirBuild.SPECIAL.length);
		var x8 = StringTools.endsWith(name, "8");
		switch name {
			case "atomic_load4" | "atomic_load8":
				var x = emit(LDAR);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
				x.size = x8 ? 8 : 4;
			case "atomic_store4" | "atomic_store8":
				var x = emit(STLR);
				x.s1 = use(i.args[0]);
				x.s2 = use(i.args[1]);
				x.size = x8 ? 8 : 4;
			case "atomic_add4" | "atomic_add8" | "atomic_xchg4" | "atomic_xchg8" | "atomic_cas4" | "atomic_cas8":
				var cas = StringTools.startsWith(name, "atomic_cas");
				var x = emit(ATOMIC);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
				x.s2 = use(i.args[cas ? 2 : 1]);
				if (cas) x.s3 = use(i.args[1]);
				x.cond = cas ? 2 : StringTools.startsWith(name, "atomic_add") ? 0 : 1;
				x.size = x8 ? 8 : 4;
				var k = emit(KEEP);
				k.s1 = x.s1;
				k.s2 = x.s2;
				k.s3 = x.s3;
			case "fence":
				emit(DMB);
			case "floor" | "ceil":
				var x = emit(FOP1);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
				x.cond = name == "floor" ? 4 : 5;
			case "f32_to_f64":
				var t = f.newReg(true);
				var x = emit(FMOVSW);
				x.d = t;
				x.s1 = use(i.args[0]);
				var c = emit(FCVTSD);
				c.d = reg(i.id);
				c.s1 = t;
			case "f64_to_f32":
				var t = f.newReg(true);
				var c = emit(FCVTDS);
				c.d = t;
				c.s1 = use(i.args[0]);
				var x = emit(FMOVWS);
				x.d = reg(i.id);
				x.s1 = t;
			// a float's bits in the low half of a float register (a C call's
			// float argument, MirBuild.cCall), and back (its float result)
			case "f32bits_to_freg":
				var x = emit(FMOVSW);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
			case "freg_to_f32bits":
				var x = emit(FMOVWS);
				x.d = reg(i.id);
				x.s1 = use(i.args[0]);
			case _:
				throw new hxmc.MirBuild.Unsupported("unknown special " + i.sym);
		}
	}

	// ---- calls (IselBase.call)

	override function floatBits(d:Int, v:Int) {
		var fm = emit(FMOVTOG);
		fm.d = d;
		fm.s1 = use(v);
	}

	// ---- vectors (hxmc.simd, docs/plans/simd.md): NEON, each operation
	// WebAssembly's (SimdOps) with its exact results (NEON's own saturating
	// conversions and NaN-propagating min and max are wasm's)

	inline function vtmp():Int
		return f.newVecReg();

	// one instruction: enc with Rd d, Rn n, Rm m (-1: none); rd: Rd is read too
	function nv(enc:Int, d:Int, n:Int, m:Int = -1, rd = false) {
		var x = emit(NV);
		x.imm = enc;
		x.d = d;
		x.s1 = n;
		x.s2 = m;
		x.flag = rd;
	}

	function vconst(d:Int, words:Array<Int>) {
		var x = emit(VCONST);
		x.d = d;
		x.uses = Vector.fromArrayCopy(words);
	}

	inline function vcopy(d:Int, s:Int)
		mov(d, s, 16);

	// the size field of a lane width (bytes)
	static inline function sizeOf(w:Int):Int
		return w == 1 ? 0 : w == 2 ? 1 : w == 4 ? 2 : 3;

	// three registers, the same arrangement (Q = 1): integer
	static inline function same3(u:Int, w:Int, opcode:Int):Int
		return 0x4E200400 | (u << 29) | (sizeOf(w) << 22) | (opcode << 11);

	// float: a the size field's top bit, sz 0 single, 1 double
	static inline function fsame3(u:Int, a:Int, d:Bool, opcode:Int):Int
		return 0x4E200400 | (u << 29) | (a << 23) | ((d ? 1 : 0) << 22) | (opcode << 11);

	// two registers (Q = 1)
	static inline function misc2(u:Int, size:Int, opcode:Int):Int
		return 0x4E200800 | (u << 29) | (size << 22) | (opcode << 12);

	// a logical operation (and 0, bic 1, orr 2, orn 3; eor 4, bsl 5, bit 6, bif 7)
	static inline function logic(k:Int):Int
		return same3(k >> 2, 1 << (k & 3), 0x03) & ~(3 << 22) | ((k & 3) << 22);

	static function width(n:String):Int
		return StringTools.startsWith(n, "i8x16") ? 1 : StringTools.startsWith(n, "i16x8") ? 2 : StringTools.startsWith(n, "i64x2") || StringTools.startsWith(n, "f64x2") ? 8 : 4;

	// imm5 of a lane (dup, ins, umov, smov)
	static inline function imm5(w:Int, lane:Int):Int
		return w == 1 ? (lane << 1) | 1 : w == 2 ? (lane << 2) | 2 : w == 4 ? (lane << 3) | 4 : (lane << 4) | 8;

	// an I32 value into a fresh general register, masked to a shift's lane width
	function shiftCount(v:Int, w:Int):Int {
		var g = f.newReg(false);
		var x = emit(ALUI);
		x.d = g;
		x.s1 = use(v);
		x.cond = 2; // and
		x.imm = w * 8 - 1;
		x.size = 4;
		return g;
	}

	function vop(i:MIns) {
		var n = SimdOps.name(i.imm);
		var w = width(n);
		var fl = StringTools.startsWith(n, "f32x4") || StringTools.startsWith(n, "f64x2"), dbl = StringTools.startsWith(n, "f64x2");
		var op = n.substr(n.indexOf(".") + 1);
		inline function A():Int
			return use(i.a);
		inline function B():Int
			return use(i.b);
		inline function D():Int
			return reg(i.id);
		inline function bin(enc:Int)
			nv(enc, D(), A(), B());
		inline function rbin(enc:Int)
			nv(enc, D(), B(), A());
		inline function un(enc:Int)
			nv(enc, D(), A());
		function not(d:Int)
			nv(misc2(1, 0, 0x05), d, d);
		switch op {
			case "and": bin(logic(0));
			case "andnot": bin(logic(1));
			case "or": bin(logic(2));
			case "xor": bin(logic(4));
			case "not": un(misc2(1, 0, 0x05));
			case "bitselect":
				// bsl: Rd (the mask) selects Rn where set, else Rm
				var d = D();
				vcopy(d, use(i.c));
				nv(logic(5), d, A(), B(), true);
			case "any_true":
				var t = vtmp(), g = f.newReg(false);
				nv(0x6EB0A800, t, A()); // umaxv s, v.4s
				nv(0x0E043C00, g, t); // umov w, v.s[0]
				cmpZero(g);
				cset(D(), Asm.NE);
			case "all_true":
				var t = vtmp(), g = f.newReg(false);
				if (w == 8) {
					nv(misc2(0, 3, 0x09), t, A()); // cmeq v.2d, #0
					nv(0x6EB0A800, t, t); // umaxv: any lane zero
					nv(0x0E043C00, g, t);
					cmpZero(g);
					cset(D(), Asm.EQ);
				} else {
					nv(0x6E31A800 | (sizeOf(w) << 22), t, A()); // uminv
					nv(0x0E003C00 | (imm5(w, 0) << 16), g, t); // umov w, v.T[0]
					cmpZero(g);
					cset(D(), Asm.NE);
				}
			case "bitmask":
				bitmask(i, w);
			// integer lanes
			case "add" if (!fl): bin(same3(0, w, 0x10));
			case "sub" if (!fl): bin(same3(1, w, 0x10));
			case "mul" if (!fl): bin(same3(0, w, 0x13));
			case "add_sat_s": bin(same3(0, w, 0x01));
			case "add_sat_u": bin(same3(1, w, 0x01));
			case "sub_sat_s": bin(same3(0, w, 0x05));
			case "sub_sat_u": bin(same3(1, w, 0x05));
			case "max_s": bin(same3(0, w, 0x0c));
			case "max_u": bin(same3(1, w, 0x0c));
			case "min_s": bin(same3(0, w, 0x0d));
			case "min_u": bin(same3(1, w, 0x0d));
			case "avgr_u": bin(same3(1, w, 0x02));
			case "q15mulr_sat_s": bin(same3(1, 2, 0x16));
			case "dot_i16x8_s":
				var t1 = vtmp(), t2 = vtmp(), a = A(), b = B();
				nv(0x0E60C000, t1, a, b); // smull v.4s, a.4h, b.4h
				nv(0x4E60C000, t2, a, b); // smull2
				nv(same3(0, 4, 0x17), D(), t1, t2); // addp v.4s
			case "abs" if (!fl): un(misc2(0, sizeOf(w), 0x0b));
			case "neg" if (!fl): un(misc2(1, sizeOf(w), 0x0b));
			case "eq" if (!fl): bin(same3(1, w, 0x11));
			case "ne" if (!fl):
				var d = D();
				nv(same3(1, w, 0x11), d, A(), B());
				not(d);
			case "gt_s": bin(same3(0, w, 0x06));
			case "lt_s": rbin(same3(0, w, 0x06));
			case "ge_s": bin(same3(0, w, 0x07));
			case "le_s": rbin(same3(0, w, 0x07));
			case "gt_u": bin(same3(1, w, 0x06));
			case "lt_u": rbin(same3(1, w, 0x06));
			case "ge_u": bin(same3(1, w, 0x07));
			case "le_u": rbin(same3(1, w, 0x07));
			case "narrow_i16x8_s" | "narrow_i16x8_u" | "narrow_i32x4_s" | "narrow_i32x4_u":
				// sqxtn (sqxtun) of a into the low half, sqxtn2 of b into the high one
				var u = StringTools.endsWith(op, "_u");
				var size = StringTools.startsWith(op, "narrow_i16") ? 0 : 1;
				var enc = u ? misc2(1, size, 0x12) : misc2(0, size, 0x14);
				var d = D(), b = B();
				nv(enc & ~(1 << 30), d, A());
				nv(enc, d, b, -1, true);
			case "extend_low_i8x16_s" | "extend_high_i8x16_s" | "extend_low_i16x8_s" | "extend_high_i16x8_s" | "extend_low_i32x4_s" | "extend_high_i32x4_s"
				| "extend_low_i8x16_u" | "extend_high_i8x16_u" | "extend_low_i16x8_u" | "extend_high_i16x8_u" | "extend_low_i32x4_u" | "extend_high_i32x4_u":
				// sshll / ushll #0, the high half with Q
				var src = op.indexOf("i8x16") > 0 ? 8 : op.indexOf("i16x8") > 0 ? 16 : 32;
				var u = StringTools.endsWith(op, "_u") ? 1 : 0;
				var q = StringTools.startsWith(op, "extend_high") ? 1 : 0;
				un(0x0F00A400 | (q << 30) | (u << 29) | (src << 16));
			case "swizzle":
				bin(0x4E000000); // tbl: from 16 on, 0
			case "shuffle":
				shuffle(i);
			case "shl" | "shr_s" | "shr_u":
				vshift(i, op, w);
			// float lanes
			case "add": bin(fsame3(0, 0, dbl, 0x1a));
			case "sub": bin(fsame3(0, 1, dbl, 0x1a));
			case "mul": bin(fsame3(1, 0, dbl, 0x1b));
			case "div": bin(fsame3(1, 0, dbl, 0x1f));
			case "max": bin(fsame3(0, 0, dbl, 0x1e));
			case "min": bin(fsame3(0, 1, dbl, 0x1e));
			case "pmin" | "pmax":
				// pmin: b < a ? b : a (fcmgt a, b); pmax: a < b ? b : a (fcmgt b, a)
				var d = D(), a = A(), b = B();
				if (op == "pmin") nv(fsame3(1, 1, dbl, 0x1c), d, a, b) else nv(fsame3(1, 1, dbl, 0x1c), d, b, a);
				nv(logic(5), d, b, a, true);
			case "eq": bin(fsame3(0, 0, dbl, 0x1c));
			case "ne":
				var d = D();
				nv(fsame3(0, 0, dbl, 0x1c), d, A(), B());
				not(d);
			case "gt": bin(fsame3(1, 1, dbl, 0x1c));
			case "lt": rbin(fsame3(1, 1, dbl, 0x1c));
			case "ge": bin(fsame3(1, 0, dbl, 0x1c));
			case "le": rbin(fsame3(1, 0, dbl, 0x1c));
			case "abs": un(misc2(0, dbl ? 3 : 2, 0x0f));
			case "neg": un(misc2(1, dbl ? 3 : 2, 0x0f));
			case "sqrt": un(misc2(1, dbl ? 3 : 2, 0x1f));
			case "nearest": un(misc2(0, dbl ? 1 : 0, 0x18));
			case "floor": un(misc2(0, dbl ? 1 : 0, 0x19));
			case "ceil": un(misc2(0, dbl ? 3 : 2, 0x18));
			case "trunc": un(misc2(0, dbl ? 3 : 2, 0x19));
			case "trunc_sat_f32x4_s": un(misc2(0, 2, 0x1b)); // fcvtzs: saturating, NaN to 0
			case "convert_i32x4_s": un(misc2(0, 0, 0x1d)); // scvtf
			case "convert_i32x4_u": un(misc2(1, 0, 0x1d)); // ucvtf
			case "trunc_sat_f64x2_s_zero":
				var d = D();
				nv(misc2(0, 3, 0x1b), d, A()); // fcvtzs v.2d
				nv(misc2(0, 2, 0x14) & ~(1 << 30), d, d); // sqxtn v.2s (the high half zero)
			case "convert_low_i32x4_s":
				var d = D();
				nv(0x0F20A400, d, A()); // sxtl v.2d, v.2s
				nv(misc2(0, 1, 0x1d), d, d); // scvtf v.2d
			case "promote_low_f32x4": un(0x0E617800); // fcvtl v.2d, v.2s
			case "demote_f64x2_zero": un(0x0E616800); // fcvtn v.2s, v.2d (the high half zero)
			case "splat":
				var d = D();
				if (fl && !dbl) {
					var s = f.newReg(true);
					var x = emit(FCVTDS);
					x.d = s;
					x.s1 = A();
					nv(0x4E040400, d, s); // dup v.4s, v.s[0]
				} else if (dbl) nv(0x4E080400, d, A()) // dup v.2d, v.d[0]
				else nv(0x4E000C00 | (imm5(w, 0) << 16), d, A()); // dup v.T, w/x
			case "extract_lane" | "extract_lane_s" | "extract_lane_u":
				var l = i.imm2;
				if (fl && !dbl) {
					var s = f.newReg(true);
					nv(0x5E000400 | (imm5(4, l) << 16), s, A()); // dup s, v.s[l]
					var x = emit(FCVTSD);
					x.d = D();
					x.s1 = s;
				} else if (dbl) nv(0x5E000400 | (imm5(8, l) << 16), D(), A()) // dup d, v.d[l]
				else if (w == 8) nv(0x4E003C00 | (imm5(8, l) << 16), D(), A()) // umov x, v.d[l]
				else if (op == "extract_lane_s") nv(0x0E002C00 | (imm5(w, l) << 16), D(), A()) // smov w, v.T[l]
				else nv(0x0E003C00 | (imm5(w, l) << 16), D(), A()); // umov w, v.T[l]
			case "replace_lane":
				var d = D(), l = i.imm2;
				if (fl && !dbl) {
					var s = f.newReg(true);
					var x = emit(FCVTDS);
					x.d = s;
					x.s1 = B();
					vcopy(d, A());
					nv(0x6E000400 | (imm5(4, l) << 16), d, s, -1, true); // ins v.s[l], v.s[0]
				} else if (dbl) {
					var b = B();
					vcopy(d, A());
					nv(0x6E000400 | (imm5(8, l) << 16), d, b, -1, true); // ins v.d[l], v.d[0]
				} else {
					var b = B();
					vcopy(d, A());
					nv(0x4E001C00 | (imm5(w, l) << 16), d, b, -1, true); // ins v.T[l], w/x
				}
			case _:
				throw new hxmc.MirBuild.Unsupported("arm64: " + n);
		}
	}

	function cmpZero(g:Int) {
		var x = emit(CMPI);
		x.s1 = g;
		x.imm = 0;
		x.size = 4;
	}

	function cset(d:Int, cond:Int) {
		var x = emit(CSET);
		x.d = d;
		x.cond = cond;
	}

	function vshift(i:MIns, op:String, w:Int) {
		var d = reg(i.id), a = use(i.a);
		var bits = w * 8;
		var k = m.vals[i.b].op == Const ? m.vals[i.b].imm & (bits - 1) : -1;
		if (k == 0) {
			vcopy(d, a);
			return;
		}
		if (k > 0) {
			if (op == "shl") nv(0x4F005400 | ((bits + k) << 16), d, a) // shl
			else nv(0x4F000400 | ((op == "shr_u" ? 1 : 0) << 29) | ((2 * bits - k) << 16), d, a); // sshr / ushr
			return;
		}
		// by a register: the count in every lane (negated for a right shift), sshl / ushl
		var g = shiftCount(i.b, w);
		var c = vtmp();
		nv(0x4E000C00 | (imm5(w, 0) << 16), c, g); // dup v.T, w
		if (op != "shl") nv(misc2(1, sizeOf(w), 0x0b), c, c); // neg
		nv(same3(op == "shr_u" ? 1 : 0, w, 0x08), d, a, c);
	}

	function bitmask(i:MIns, w:Int) {
		var d = reg(i.id), a = use(i.a);
		var t = vtmp(), k = vtmp();
		var bits = w * 8;
		// each lane's top bit as 0 or 1 (ushr), moved to its place (ushl by its index within 8 lanes), added
		nv(0x6F000400 | ((2 * bits - (bits - 1)) << 16), t, a); // ushr #bits-1
		if (w == 8) {
			var g = f.newReg(false), h = f.newReg(false);
			nv(0x4E083C00, g, t); // umov x, v.d[0]
			nv(0x4E183C00, h, t); // umov x, v.d[1]
			var x = emit(ADDSH);
			x.d = d;
			x.s1 = g;
			x.s2 = h;
			x.imm = 1;
			x.size = 4;
			return;
		}
		var idx = switch w {
			case 1: [0x03020100, 0x07060504, 0x03020100, 0x07060504];
			case 2: [0x00010000, 0x00030002, 0x00050004, 0x00070006];
			case _: [0, 1, 2, 3];
		};
		vconst(k, idx);
		nv(same3(1, w, 0x08), t, t, k); // ushl
		if (w == 1) {
			// the two halves: addv 8b each, the high one shifted by 8
			var hi = vtmp(), g = f.newReg(false), h = f.newReg(false);
			nv(0x6E004000 | (8 << 11), hi, t, t); // ext v.16b, t, t, #8
			nv(0x0E31B800, t, t); // addv b, v.8b
			nv(0x0E31B800, hi, hi);
			nv(0x0E013C00, g, t); // umov w, v.b[0]
			nv(0x0E013C00, h, hi);
			var x = emit(ADDSH);
			x.d = d;
			x.s1 = g;
			x.s2 = h;
			x.imm = 8;
			x.size = 4;
			return;
		}
		nv(0x4E31B800 | (sizeOf(w) << 22), t, t); // addv
		nv(0x0E003C00 | (imm5(w, 0) << 16), d, t); // umov w, v.T[0]
	}

	// tbl from a (lanes below 16) and b (16 and up), or'ed (tbl gives 0 from 16 on)
	function shuffle(i:MIns) {
		var d = reg(i.id);
		var ls = i.cases;
		function mask(fromB:Bool):Array<Int> {
			var w = [0, 0, 0, 0];
			for (k in 0...16) {
				var l = ls[k];
				var byte = (l >= 16) == fromB ? l & 15 : 0xff;
				w[k >> 2] |= byte << (8 * (k & 3));
			}
			return w;
		}
		var anyA = false, anyB = false;
		for (l in ls)
			if (l < 16) anyA = true else anyB = true;
		var ta = -1;
		if (anyA) {
			var ka = vtmp();
			vconst(ka, mask(false));
			ta = anyB ? vtmp() : d;
			nv(0x4E000000, ta, use(i.a), ka);
		}
		if (anyB) {
			var kb = vtmp();
			vconst(kb, mask(true));
			var tb = anyA ? vtmp() : d;
			nv(0x4E000000, tb, use(i.b), kb);
			if (anyA) nv(logic(2), d, ta, tb);
		}
	}

	override function f32FromBits(d:Int, s:Int) {
		var fm = emit(FMOVSW);
		fm.d = d;
		fm.s1 = s;
	}

	override function stackArg(i:MIns, k:Int, loc:ArgLoc) {
		var a = i.args[k];
		if (apple && i.variadic >= 0 && k >= i.variadic) {
			var x = emit(STORE);
			x.base = -4; // outgoing argument area
			x.disp = loc.off;
			x.size = 8;
			x.s1 = use(a);
			return;
		}
		var src = use(a);
		if (i.argTys[k] == F64 && loc.size == 4) {
			// (a float: its bits through a general register)
			var g = f.newReg(false);
			var fm = emit(FMOVWS);
			fm.d = g;
			fm.s1 = src;
			src = g;
		}
		var x = emit(STORE);
		x.base = -4;
		x.disp = loc.off;
		x.size = loc.size;
		x.s1 = src;
	}

	// (a float part of 4 bytes: a single in s0-s3)
	override function loadPart(r:Int, addr:Int, p:CPart) {
		var l = emit(LOAD);
		l.d = p.float && p.size == 4 ? f.newReg(false) : r;
		l.size = p.float && p.size == 4 ? 4 : p.size == 16 ? 16 : 8;
		memOf(l, addr, -1, 1, p.off, l.size);
		if (p.float && p.size == 4) f32FromBits(r, l.d);
	}

	override function takePart(r:Int, p:CPart):Int {
		var t = p.size == 16 ? f.newVecReg() : f.newReg(p.float && p.size == 8);
		if (p.float && p.size == 4) {
			var fm = emit(FMOVWS);
			fm.d = t;
			fm.s1 = r;
		} else mov(t, r, 8);
		return t;
	}

	override function storePart(r:Int, addr:Int, p:CPart) {
		var s = emit(STORE);
		s.size = p.float && p.size == 4 ? 4 : p.size == 16 ? 16 : 8;
		s.s1 = r;
		memOf(s, addr, -1, 1, p.off, s.size);
	}
}
