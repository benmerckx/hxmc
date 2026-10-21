package hxmc.a64;

import hxmc.Mir;
import hxmc.Abi;
import hxmc.Lir;
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
	var DMB;
	var FMOVSW; // d (fpr, single) <- s1 (32 bits)
	var FMOVWS; // d (32 bits) <- s1 (fpr, single)
	var FCVTSD; // d (double) <- s1 (single)
	var FCVTDS; // d (single) <- s1 (double)
}

// Mir -> LIR for AArch64 (AAPCS64). x16/x17 are the emitter's scratch
// registers and x18 is the platform register: none of them is allocated.
class Isel implements hxmc.Target.Selector {
	public var gprs(default, null):Vector<Int> = GPRS;
	public var fprs(default, null):Vector<Int> = FPRS;

	public static inline var ZR = 31;
	static inline var D0 = 32;

	public static final ARG_GPRS:Vector<Int> = vector(0, 1, 2, 3, 4, 5, 6, 7);
	public static final CALLER_SAVED:Vector<Int> = vector(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 32, 33, 34, 35, 36, 37, 38, 39, 48, 49, 50,
		51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63);
	public static final CALLEE_SAVED:Vector<Int> = vector(19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 40, 41, 42, 43, 44, 45, 46, 47);
	// the allocatable registers in order of preference
	static final GPRS:Vector<Int> = vector(9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28);
	static final FPRS:Vector<Int> = vector(32, 33, 34, 35, 36, 37, 38, 39, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 40, 41, 42, 43,
		44, 45, 46, 47);
	static final CALL_RESULTS:Vector<Int> = vector(0, 1, 32, 33, 34, 35);

	var apple:Bool;
	var m:MFunc;
	var f:LFunc;
	var vreg:haxe.ds.Vector<Int>;
	var useCount:haxe.ds.Vector<Int>;
	var lb:Vector<LBlock>;
	var cur:LBlock;
	var folded:haxe.ds.Vector<Bool>;

	var abi:Abi;
	// the base register of thread-local variables when they are reached from
	// one (Windows: the module's TLS block; Apple: the image's TLV template),
	// computed once per function
	var tlsBase = -1;

	public function new(abi:Abi) {
		this.abi = abi;
		apple = abi.os == "macos";
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
				for (r in CALLER_SAVED)
					defs.push(r);
			case RET:
				for (x in i.uses)
					uses.push(x);
			case B | BCOND | BRK:
		}
	}

	public function isMove(i:LIns):Bool
		return i.op == MOV;

	public var callResults(default, null):Vector<Int> = CALL_RESULTS;

	public function isCall(i:LIns):Bool
		return i.op == CALL;

	public function isBranch(i:LIns):Bool
		return i.op == B || i.op == BCOND || i.op == CBZ || i.op == JTABLE || i.op == BRK;

	public function spillLoad(r:Int, slot:Int, float:Bool):LIns {
		var i = new LIns(LOAD);
		i.d = r;
		i.base = LIns.FRAME;
		i.slot = slot;
		i.size = 8;
		return i;
	}

	public function spillStore(slot:Int, r:Int, float:Bool):LIns {
		var i = new LIns(STORE);
		i.s1 = r;
		i.base = LIns.FRAME;
		i.slot = slot;
		i.size = 8;
		return i;
	}

	// ---- selection

	var pending:Null<LIns>;

	// (-debug) the source position of the Mir instruction being selected (LIns.pos)
	var curPos = 0;

	function emit(op:AOp):LIns {
		flush();
		pending = new LIns(op);
		pending.pos = curPos;
		return pending;
	}

	function flush() {
		if (pending != null) {
			cur.ins.push(pending);
			pending = null;
		}
	}

	function push(i:LIns) {
		i.pos = curPos;
		cur.ins.push(i);
	}

	inline function sz(t:MTy):Int
		return t == I32 ? 4 : 8;

	function reg(v:Int):Int {
		var r = vreg[v];
		if (r < 0) {
			r = f.newReg(m.vals[v].ty == F64);
			vreg[v] = r;
		}
		return r;
	}

	// an operand where the zero register can stand for 0 (store values, the
	// second operand of register operations, csel)
	function useZ(v:Int):Int {
		var i = m.vals[v];
		if (folded[v] && i.op == Const && i.sym == null && i.imm == 0 && (i.ty == I32 || i.imm2 == 0)) return ZR;
		return use(v);
	}

	function use(v:Int):Int {
		if (folded[v]) {
			var i = m.vals[v];
			var r = f.newReg(i.ty == F64);
			materialize(i, r);
			return r;
		}
		return reg(v);
	}

	function mov(d:Int, s:Int, size = 8) {
		if (d == s) return;
		var i = emit(MOV);
		i.d = d;
		i.s1 = s;
		i.size = size;
		if (d >= LFunc.NPHYS) f.setHint(d, s);
		if (s >= LFunc.NPHYS) f.setHint(s, d);
	}

	function isymOf(v:Int):Null<String> {
		var i = m.vals[v];
		return i.op == Const ? i.sym : null;
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

	public function select(mf:MFunc, layout:Vector<MBlock>):LFunc {
		m = mf;
		f = new LFunc(mf.name, 32);
		for (s in mf.slots)
			f.slot(s.size, s.align);
		vreg = hxmc.Lir.Arrays.filled(mf.vals.length, -1);
		useCount = hxmc.Lir.Arrays.filled(mf.vals.length, 0);
		folded = new haxe.ds.Vector(mf.vals.length);
		for (b in mf.blocks)
			for (i in b.ins) {
				for (x in [i.a, i.b, i.c])
					if (x >= 0) useCount[x]++;
				for (x in i.args)
					useCount[x]++;
			}
		for (b in mf.blocks)
			for (i in b.ins)
				if (i.op == Const || i.op == SymAddr || i.op == StackAddr) folded[i.id] = true;
		var maxId = 0;
		for (b in mf.blocks)
			if (b.id >= maxId) maxId = b.id + 1;
		lb = new Vector<LBlock>(maxId);
		for (b in layout) {
			var l = new LBlock(f.blocks.length);
			l.cold = b.cold;
			lb[b.id] = l;
			f.blocks.push(l);
		}
		tlsBase = -1;
		var usesTls = false;
		if (abi.tls != LocalExec)
			for (b in mf.blocks)
				for (i in b.ins)
					if (i.op == TlsLoad || i.op == TlsStore) usesTls = true;
		if (usesTls && abi.tls == WinTlsIndex) {
			// ThreadLocalStoragePointer[_tls_index] (x18 + 0x58 is the pointer array)
			cur = lb[layout[0].id];
			var idx = f.newReg(false), arr = f.newReg(false);
			tlsBase = f.newReg(false);
			var x = emit(LOAD);
			x.d = idx;
			x.sym = "_tls_index";
			x.size = 4;
			var g = emit(TEBLOAD);
			g.d = arr;
			g.imm = 0x58;
			var l = emit(LOAD);
			l.d = tlsBase;
			l.base = arr;
			l.index = idx;
			l.scale = 8;
			l.size = 8;
			flush();
		}
		for (bi in 0...layout.length) {
			var b = layout[bi];
			cur = lb[b.id];
			var next = bi + 1 < layout.length ? layout[bi + 1] : null;
			// (Android's TLSDESC: the module's block from hxmc_tls_base too, LinkDyn)
			var pendingBase = bi == 0 && usesTls && (abi.tls == MachoTlv || abi.tls == Desc);
			// after the last parameter (the call clobbers their registers;
			// constants such as MirBuild.zeroAt's may come before them)
			var lastParam = -1;
			if (pendingBase)
				for (k in 0...b.ins.length)
					if (b.ins[k].op == Param) lastParam = k;
			for (k in 0...b.ins.length) {
				var i = b.ins[k];
				if (pendingBase && k > lastParam) {
					pendingBase = false;
					macTlsBase();
				}
				curPos = i.pos;
				ins(i, b, next);
			}
			if (pendingBase) macTlsBase();
			flush();
		}
		for (l in f.blocks) {
			l.succs = [];
			for (i in l.ins) {
				if (i.target != null && l.succs.indexOf(i.target) < 0) l.succs.push(i.target);
				for (t in i.table)
					if (l.succs.indexOf(t) < 0) l.succs.push(t);
			}
		}
		for (l in f.blocks)
			for (s in l.succs)
				s.preds.push(l);
		return f;
	}

	// Apple: the address of the image's thread-local template for this
	// thread (hxmc_tls_base in the runtime, through a TLV descriptor), once
	// the parameters are out of their registers
	function macTlsBase() {
		f.hasCalls = true;
		tlsBase = f.newReg(false);
		var x = emit(CALL);
		x.sym = "hxmc_tls_base";
		mov(tlsBase, 0, 8);
	}

	function materialize(i:MIns, r:Int) {
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

	function jmp(t:LBlock) {
		var x = emit(B);
		x.target = t;
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

	static function swap(c:Int):Int
		return switch (c : Cond) {
			case CLt: CGt;
			case CLe: CGe;
			case CGt: CLt;
			case CGe: CLe;
			case CULt: CUGt;
			case CULe: CUGe;
			case CUGt: CULt;
			case CUGe: CULe;
			case c: c;
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
			return cond(swap(c));
		}
		var x = emit(CMP);
		x.s1 = use(a);
		x.s2 = use(b);
		x.size = sz(t);
		return cond(c);
	}

	function phiCopies(from:MBlock, to:MBlock) {
		var k = to.preds.indexOf(from);
		var phis = [for (i in to.ins) if (i.op == Phi) i];
		if (phis.length == 0) return;
		var needTemp = false;
		for (p in phis)
			for (q in phis)
				if (p.args[k] == q.id && p != q) needTemp = true;
		if (!needTemp) {
			for (p in phis)
				if (p.args[k] != p.id) copyTo(reg(p.id), p.args[k]);
			return;
		}
		var temps = new Vector<Int>(phis.length), nt = 0;
		for (p in phis) {
			var t = f.newReg(p.ty == F64);
			copyTo(t, p.args[k]);
			temps[nt++] = t;
		}
		for (j in 0...phis.length)
			mov(reg(phis[j].id), temps[j], 8);
	}

	function copyTo(d:Int, v:Int) {
		if (folded[v]) materialize(m.vals[v], d) else mov(d, reg(v), 8);
	}

	function edgeTarget(b:MBlock, to:MBlock):LBlock {
		if (!(to.ins.length > 0 && to.ins[0].op == Phi)) return lb[to.id];
		flush();
		var e = new LBlock(f.blocks.length);
		e.cold = lb[to.id].cold;
		f.blocks.push(e);
		var saved = cur;
		cur = e;
		phiCopies(b, to);
		jmp(lb[to.id]);
		flush();
		cur = saved;
		return e;
	}

	function fusable(i:MIns, b:MBlock):Bool {
		if (useCount[i.id] != 1) return false;
		var t = b.term();
		if (t == null || t.op != Br || t.a != i.id) return false;
		if (b.ins.length < 2 || b.ins[b.ins.length - 2] != i) return false;
		folded[i.id] = true;
		return true;
	}

	function aluOp(op:Op):Int
		return switch op {
			case Add: 0;
			case Sub: 1;
			case And: 2;
			case Or: 3;
			case _: 4;
		};

	function ins(i:MIns, b:MBlock, next:Null<MBlock>) {
		switch i.op {
			case Phi | Const | SymAddr | StackAddr:
			case Param if (i.imm < 0):
				// (x8: the address of the struct result, MirBuild.cEntry)
				mov(reg(i.id), 8);
			case Param if (m.cParams.length > 0):
				var loc = paramLocs()[i.imm];
				var d = reg(i.id);
				if (loc.reg >= 0) mov(d, loc.reg) else if (loc.size == 4 && i.ty == F64) {
					var g = f.newReg(false);
					var x = emit(LOAD);
					x.d = g;
					x.base = -3;
					x.disp = loc.off;
					x.size = 4;
					var fm = emit(FMOVSW);
					fm.d = d;
					fm.s1 = g;
				} else {
					var x = emit(LOAD);
					x.d = d;
					x.base = -3;
					x.disp = loc.off;
					x.size = loc.size;
				}
			case Param:
				var k = i.imm;
				// (stack arguments: 8-byte slots; Apple packs them by size)
				var gi = 0, fi = 0, so = 0;
				inline function slotSize(t:MTy)
					return apple && t == I32 ? 4 : 8;
				for (j in 0...k)
					if (m.params[j] == F64) {
						if (fi < 8) fi++ else so += 8;
					} else {
						if (gi < 8) gi++ else {
							var sz = slotSize(m.params[j]);
							so = ((so + sz - 1) & ~(sz - 1)) + sz;
						}
					}
				var d = reg(i.id);
				if (i.ty == F64 && fi < 8) mov(d, D0 + fi) else if (i.ty != F64 && gi < 8) mov(d, ARG_GPRS[gi]) else {
					var sz = i.ty == F64 ? 8 : slotSize(m.params[k]);
					var x = emit(LOAD);
					x.d = d;
					x.base = -3;
					x.disp = (so + sz - 1) & ~(sz - 1);
					x.size = sz;
				}
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
				if (useCount[i.id] == 0) return; // unused (MirBuild.cmp folded it)
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
				var x = emit(STORE);
				x.size = i.size;
				x.s1 = useZ(i.c);
				memOf(x, i.a, i.b, i.imm2, i.imm, i.size);
			case Call if (i.sym != null && StringTools.startsWith(i.sym, hxmc.MirBuild.SPECIAL)):
				special(i);
			case Call:
				call(i);
			case Jmp:
				phiCopies(b, i.targets[0]);
				jmp(lb[i.targets[0].id]);
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
				var rs = new Vector<Int>(m.cRet.length), nr = 0;
				for (p in m.cRet) {
					var r = f.newReg(p.float);
					var l = emit(LOAD);
					l.d = p.float && p.size == 4 ? f.newReg(false) : r;
					l.size = p.float && p.size == 4 ? 4 : 8;
					memOf(l, i.a, -1, 1, p.off, l.size);
					if (p.float && p.size == 4) {
						var fm = emit(FMOVSW);
						fm.d = r;
						fm.s1 = l.d;
					}
					rs[nr++] = r;
				}
				var x = new LIns(RET);
				x.uses = new Vector(rs.length);
				var gk = 0, fk = 0;
				for (k in 0...rs.length) {
					var d = m.cRet[k].float ? D0 + fk++ : gk++;
					mov(d, rs[k], 8);
					x.uses[k] = d;
				}
				flush();
				push(x);
			case Ret:
				var x = new LIns(RET);
				if (i.a >= 0) {
					var r = m.vals[i.a].ty == F64 ? D0 : 0;
					mov(r, use(i.a), 8);
					x.uses = vector(r);
				}
				flush();
				push(x);
			case Unreachable:
				emit(BRK);
		}
	}

	function switchIns(i:MIns, b:MBlock) {
		var v = use(i.a);
		var def = edgeTarget(b, i.targets[i.targets.length - 1]);
		var n = i.cases.length;
		if (n == 0) {
			jmp(def);
			return;
		}
		var lo = i.cases[0], hi = i.cases[0];
		for (c in i.cases) {
			if (c < lo) lo = c;
			if (c > hi) hi = c;
		}
		var targets = new Vector<LBlock>(n);
		for (k in 0...n)
			targets[k] = edgeTarget(b, i.targets[k]);
		var span = hi - lo + 1;
		if (n >= 4 && span > 0 && span <= 3 * n + 8) {
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
			var table = new Vector<LBlock>(span, def);
			for (k in 0...n)
				table[i.cases[k] - lo] = targets[k];
			var j = emit(JTABLE);
			j.s1 = idx;
			j.table = table;
			return;
		}
		for (k in 0...n) {
			var cv = i.cases[k];
			if (addImm(cv)) {
				var c = emit(CMPI);
				c.s1 = v;
				c.imm = cv;
				c.size = 4;
			} else {
				var t = f.newReg(false);
				var mi = emit(MOVI);
				mi.d = t;
				mi.imm = cv;
				mi.size = 4;
				var c = emit(CMP);
				c.s1 = v;
				c.s2 = t;
				c.size = 4;
			}
			bcond(Asm.EQ, targets[k]);
		}
		jmp(def);
	}

	// the inline expansions of MirBuild.special: atomics (sequentially
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

	// where the parameters of a function entered from C with structs by
	// value are (MFunc.cParams): a register, or a stack slot of the caller
	// (offset, size), placed as call places arguments
	var pLocs:Null<Vector<{reg:Int, off:Int, size:Int}>> = null;
	var pLocsOf:Null<MFunc> = null;

	function paramLocs():Vector<{reg:Int, off:Int, size:Int}> {
		if (pLocsOf == m) return pLocs;
		var r = new Vector<{reg:Int, off:Int, size:Int}>(m.params.length);
		var gi = 0, fi = 0, stack = 0, spill = 0;
		for (k in 0...m.params.length) {
			var t = m.params[k];
			var parts = m.cParams[k];
			if (parts > 1 && (t == F64 ? fi : gi) + parts > 8) {
				if (t == F64) fi = 8 else gi = 8;
				spill = parts;
				var al = apple ? m.cParamSizes[k] : 8;
				stack = (stack + al - 1) & ~(al - 1);
			}
			if (t == F64 && fi < 8) {
				r[k] = {reg: D0 + fi++, off: 0, size: 8};
				continue;
			}
			if (t != F64 && gi < 8) {
				r[k] = {reg: ARG_GPRS[gi++], off: 0, size: 8};
				continue;
			}
			var size = !apple && spill == 0 ? 8 : m.cParamSizes[k];
			stack = (stack + size - 1) & ~(size - 1);
			if (spill > 0) spill--;
			r[k] = {reg: -1, off: stack, size: size};
			stack += size;
		}
		pLocs = r;
		pLocsOf = m;
		return r;
	}

	function call(i:MIns) {
		f.hasCalls = true;
		var gi = 0, fi = 0, stack = 0;
		var winVariadic = abi.os == "windows" && i.variadic >= 0;
		var uses = [];
		var moves:Array<{d:Int, s:Int}> = [];
		// (a struct result: its address is the last argument, in x8 when the
		// callee stores it, MirBuild.cStructRet)
		var n = i.structRet ? i.args.length - 1 : i.args.length;
		if (i.structRet && i.cRet.length == 0) {
			moves.push({d: 8, s: i.args[n]});
			uses.push(8);
		}
		// the parts of a struct argument left to place on the stack (none in registers)
		var spill = 0;
		for (k in 0...n) {
			var a = i.args[k];
			var t = i.argTys[k];
			var parts = i.cGroups.length > 0 ? i.cGroups[k] : 1;
			if (parts > 1 && (t == F64 ? fi : gi) + parts > 8) {
				if (t == F64) fi = 8 else gi = 8;
				spill = parts;
				// (AAPCS64: the struct's memory at an 8-byte boundary; Apple aligns it to its parts)
				var al = apple ? i.cSizes[k] : 8;
				stack = (stack + al - 1) & ~(al - 1);
			}
			// Apple: variadic arguments on the stack, 8 bytes each
			var onStack = apple && i.variadic >= 0 && k >= i.variadic;
			if (onStack) {
				stack = (stack + 7) & ~7;
				var x = emit(STORE);
				x.base = -4;
				x.disp = stack;
				x.size = 8;
				x.s1 = use(a);
				stack += 8;
				continue;
			}
			// Windows: a variadic function takes every argument as an integer
			// (x0-x7, then the stack), floats as their bits
			if (t == F64 && winVariadic) {
				var g = f.newReg(false);
				var fm = emit(FMOVTOG);
				fm.d = g;
				fm.s1 = use(a);
				if (gi < 8) {
					moves.push({d: ARG_GPRS[gi], s: -1 - g});
					uses.push(ARG_GPRS[gi]);
					gi++;
				} else {
					var x = emit(STORE);
					x.base = -4;
					x.disp = stack;
					x.size = 8;
					x.s1 = g;
					stack += 8;
				}
				continue;
			}
			if (t == F64) {
				if (fi < 8) {
					moves.push({d: D0 + fi, s: a});
					uses.push(D0 + fi);
					fi++;
					continue;
				}
			} else if (gi < 8) {
				moves.push({d: ARG_GPRS[gi], s: a});
				uses.push(ARG_GPRS[gi]);
				gi++;
				continue;
			}
			// stack argument (Apple packs them by their C size; 8-byte slots
			// elsewhere, except inside a struct, whose memory they are)
			var size = !apple && spill == 0 ? 8 : k < i.cSizes.length ? i.cSizes[k] : t == I32 ? 4 : 8;
			stack = (stack + size - 1) & ~(size - 1);
			if (spill > 0) spill--;
			var src = use(a);
			if (t == F64 && size == 4) {
				// (a float: its bits through a general register)
				var g = f.newReg(false);
				var fm = emit(FMOVWS);
				fm.d = g;
				fm.s1 = src;
				src = g;
			}
			var x = emit(STORE);
			x.base = -4;
			x.disp = stack;
			x.size = size;
			x.s1 = src;
			stack += size;
		}
		stack = (stack + 7) & ~7;
		if (stack > f.outArgs) f.outArgs = stack;
		var target = i.sym == null ? use(i.a) : -1;
		for (mv in moves)
			if (mv.s < 0) mov(mv.d, -1 - mv.s, 8) // (a register of this call's own: -1 - its number)
			else if (folded[mv.s]) materialize(m.vals[mv.s], mv.d) else mov(mv.d, reg(mv.s), 8);
		var x = emit(CALL);
		x.sym = i.sym;
		x.s1 = target;
		x.uses = Vector.fromArrayCopy(uses);
		if (i.ty != Void) mov(reg(i.id), i.ty == F64 ? D0 : 0, 8);
		if (i.structRet && i.cRet.length > 0) {
			// a struct in x0-x1 or d0-d3 (s0-s3): out of them first, then into its memory
			var rs = new Vector<Int>(i.cRet.length), nr = 0, gk = 0, fk = 0;
			for (p in i.cRet) {
				var r = f.newReg(p.float && p.size == 8);
				if (p.float && p.size == 4) {
					var fm = emit(FMOVWS);
					fm.d = r;
					fm.s1 = D0 + fk++;
				} else mov(r, p.float ? D0 + fk++ : gk++, 8);
				rs[nr++] = r;
			}
			for (k in 0...i.cRet.length) {
				var p = i.cRet[k];
				var s = emit(STORE);
				s.size = p.float && p.size == 4 ? 4 : 8;
				s.s1 = rs[k];
				memOf(s, i.args[n], -1, 1, p.off, s.size);
			}
		}
	}
}
