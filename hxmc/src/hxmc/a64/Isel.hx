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
	var SDIV;
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

	var apple:Bool;

	public function new(abi:Abi) {
		super(abi);
		apple = abi.os == "macos";
		gprs = GPRS;
		fprs = FPRS;
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
			case Div:
				var x = emit(SDIV);
				x.d = reg(i.id);
				x.s1 = use(i.a);
				x.s2 = use(i.b);
				x.size = sz(i.ty);
			case Rem:
				var a = use(i.a), bb = use(i.b);
				var q = f.newReg(false);
				var x = emit(SDIV);
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
				NArrayGet | NArraySet | NArrayDyn | RefStore | IrNode | VarGet | VarSet | Try | Catch:
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
				if (cv.op == Cmp && useCount[cv.id] == 1 && cv.block == b) {
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
		l.size = p.float && p.size == 4 ? 4 : 8;
		memOf(l, addr, -1, 1, p.off, l.size);
		if (p.float && p.size == 4) f32FromBits(r, l.d);
	}

	override function takePart(r:Int, p:CPart):Int {
		var t = f.newReg(p.float && p.size == 8);
		if (p.float && p.size == 4) {
			var fm = emit(FMOVWS);
			fm.d = t;
			fm.s1 = r;
		} else mov(t, r, 8);
		return t;
	}

	override function storePart(r:Int, addr:Int, p:CPart) {
		var s = emit(STORE);
		s.size = p.float && p.size == 4 ? 4 : 8;
		s.s1 = r;
		memOf(s, addr, -1, 1, p.off, s.size);
	}
}
