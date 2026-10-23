package hxmc;

import hxmc.Mir;
import hxmc.Abi;
import hxmc.Lir;
import hxmc.CallConv;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// The skeleton of instruction selection (Mir -> LIR) both architectures
// share (x64.Isel, a64.Isel): the walk over the blocks in layout order, use
// counts, the LIR blocks, the thread-local base (Windows' TLS block, Apple's
// and Android's from hxmc_tls_base), phi copies on the edges (critical ones
// split, parallel copies through temporaries), the switch strategy, the
// parameters and the calls as the ABI's CallConv places them, and the
// successor and predecessor edges. An architecture gives its operations
// (the op* fields), its own folding (prepare), the instructions themselves
// (ins), materialisation, compare and branch, and the hooks of switches and
// calls below.
class IselBase {
	public var gprs(default, null):Vector<Int>;
	public var fprs(default, null):Vector<Int>;
	public var callResults(default, null):Vector<Int>;

	var abi:Abi;
	var cc:CallConv;

	// the architecture's LIR operations the skeleton emits
	var opMov:Int;
	var opLoad:Int;
	var opStore:Int;
	var opJmp:Int;
	var opCall:Int;
	var opRet:Int;
	var opTeb:Int; // d <- [the thread environment block + imm] (Windows)
	// the first float register of LFunc
	var fprBase:Int;

	var m:MFunc;
	var f:LFunc;
	var vreg:Vector<Int>; // Mir value -> register
	var useCount:Vector<Int>;
	var lb:Vector<LBlock>; // Mir block id -> LBlock
	var cur:LBlock;
	var folded:Vector<Bool>; // Mir values computed inside their user (no code of their own)
	// the base register of thread-local variables when they are reached from
	// one (Windows: the module's TLS block; Apple, Android's TLSDESC: the
	// image's block from hxmc_tls_base), computed once per function
	var tlsBase = -1;

	function new(abi:Abi) {
		this.abi = abi;
		cc = CallConv.of(abi);
		callResults = cc.callResults;
	}

	// ---- RegTarget (with the architecture's defsUses)

	public function isMove(i:LIns):Bool
		return i.op == opMov;

	public function isCall(i:LIns):Bool
		return i.op == opCall;

	public function spillLoad(r:Int, slot:Int, float:Bool):LIns {
		var i = new LIns(opLoad);
		i.d = r;
		i.base = LIns.FRAME;
		i.slot = slot;
		i.size = 8;
		return i;
	}

	public function spillStore(slot:Int, r:Int, float:Bool):LIns {
		var i = new LIns(opStore);
		i.s1 = r;
		i.base = LIns.FRAME;
		i.slot = slot;
		i.size = 8;
		return i;
	}

	// ---- emitting

	// The instruction being filled in is appended once the next one starts
	// (flush), so the constants and addresses its operands materialize
	// (`use`) come before it.
	var pending:Null<LIns>;

	// (-debug) the source position of the Mir instruction being selected (LIns.pos)
	var curPos = 0;

	function emit(op:Int):LIns {
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

	// an operand as a register, materializing folded constants
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
		var i = emit(opMov);
		i.d = d;
		i.s1 = s;
		i.size = size;
		if (d >= LFunc.NPHYS) f.setHint(d, s);
		if (s >= LFunc.NPHYS) f.setHint(s, d);
	}

	// the absolute symbol of a symbolic constant (its immediate is the addend)
	function isymOf(v:Int):Null<String> {
		var i = m.vals[v];
		return i.op == Const ? i.sym : null;
	}

	function jmp(t:LBlock) {
		var x = emit(opJmp);
		x.target = t;
	}

	function log2(v:Int):Int {
		var k = 0;
		while (v > 1) {
			v >>>= 1;
			k++;
		}
		return k;
	}

	// the condition with its operands swapped
	function swapCond(c:Int):Int
		return switch (c : Cond) {
			case CLt: CGt;
			case CLe: CGe;
			case CGt: CLt;
			case CGe: CLe;
			case CULt: CUGt;
			case CULe: CUGe;
			case CUGt: CULt;
			case CUGe: CULe;
			case FLt: FGt;
			case FLe: FGe;
			case FGt: FLt;
			case FGe: FLe;
			case c: c;
		};

	// ---- the architecture's part

	// after the use counts, before any block: what the architecture folds
	// into its users (marks folded)
	function prepare() {}

	// one Mir instruction of block b (next: the block laid out after it)
	function ins(i:MIns, b:MBlock, next:Null<MBlock>)
		throw "abstract";

	// a folded value into register r
	function materialize(i:MIns, r:Int)
		throw "abstract";

	// ---- the walk

	public function select(mf:MFunc, layout:Vector<MBlock>):LFunc {
		m = mf;
		f = new LFunc(mf.name, fprBase);
		for (s in mf.slots)
			f.slot(s.size, s.align);
		vreg = hxmc.Lir.Arrays.filled(mf.vals.length, -1);
		useCount = hxmc.Lir.Arrays.filled(mf.vals.length, 0);
		folded = new Vector(mf.vals.length);
		for (b in mf.blocks)
			for (i in b.ins) {
				if (i.a >= 0) useCount[i.a]++;
				if (i.b >= 0) useCount[i.b]++;
				if (i.c >= 0) useCount[i.c]++;
				for (x in i.args)
					useCount[x]++;
			}
		prepare();
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
			// Windows: the thread's TLS block once per function,
			// ThreadLocalStoragePointer[_tls_index] (TEB + 0x58 is the pointer array)
			cur = lb[layout[0].id];
			var idx = f.newReg(false), arr = f.newReg(false);
			tlsBase = f.newReg(false);
			var x = emit(opLoad);
			x.d = idx;
			x.sym = "_tls_index";
			x.size = 4;
			var g = emit(opTeb);
			g.d = arr;
			g.imm = 0x58;
			var l = emit(opLoad);
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
			// Apple: the image's thread-local template for this thread
			// (hxmc_tls_base in the runtime); Android's TLSDESC: the module's
			// block from hxmc_tls_base too (LinkDyn)
			var pendingBase = bi == 0 && usesTls && (abi.tls == MachoTlv || abi.tls == Desc);
			// after the last parameter (the call clobbers their registers;
			// constants such as MirWriter.zeroAt's may come before them)
			var lastParam = -1;
			if (pendingBase)
				for (k in 0...b.ins.length)
					if (b.ins[k].op == Param) lastParam = k;
			for (k in 0...b.ins.length) {
				var i = b.ins[k];
				if (pendingBase && k > lastParam) {
					pendingBase = false;
					tlsBaseCall();
				}
				curPos = i.pos;
				ins(i, b, next);
			}
			if (pendingBase) tlsBaseCall();
			flush();
		}
		// successor edges (for liveness), including the critical-edge blocks added on the way
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

	// tlsBase from hxmc_tls_base (through a TLV descriptor on Apple)
	function tlsBaseCall() {
		f.hasCalls = true;
		tlsBase = f.newReg(false);
		var x = emit(opCall);
		x.sym = "hxmc_tls_base";
		mov(tlsBase, cc.result(false), 8);
	}

	// ---- edges

	// the copies of the phis of `to` for the edge from `from`
	function phiCopies(from:MBlock, to:MBlock) {
		var k = to.preds.indexOf(from);
		var phis = [for (i in to.ins) if (i.op == Phi) i];
		if (phis.length == 0) return;
		// through temporaries when a phi's operand is another phi of the same block
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

	// a branch from Mir block b to `to`: through an edge block when the edge is critical
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

	function jmpIns(i:MIns, b:MBlock) {
		phiCopies(b, i.targets[0]);
		jmp(lb[i.targets[0].id]);
	}

	// a comparison used only by the branch right after it (nothing between
	// them changes the flags); marks it folded
	function fusable(i:MIns, b:MBlock):Bool {
		if (useCount[i.id] != 1) return false;
		var t = b.term();
		if (t == null || t.op != Br || t.a != i.id) return false;
		if (b.ins.length < 2 || b.ins[b.ins.length - 2] != i) return false;
		folded[i.id] = true;
		return true;
	}

	function objectLevel(i:MIns)
		throw "isel: " + MFunc.opName(i.op) + " is object-level (MemLower lowers it first)";

	// ---- switches: a jump table when the cases are dense enough, else a
	// comparison per case

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
			var table = new Vector<LBlock>(span, def);
			for (k in 0...n)
				table[i.cases[k] - lo] = targets[k];
			jumpTable(v, lo, span, def, table);
			return;
		}
		for (k in 0...n)
			caseBranch(v, i.cases[k], targets[k]);
		jmp(def);
	}

	// the jump through table on v - lo, to def when it is not below span
	function jumpTable(v:Int, lo:Int, span:Int, def:LBlock, table:Vector<LBlock>)
		throw "abstract";

	// to t when v (32 bits) is c
	function caseBranch(v:Int, c:Int, t:LBlock)
		throw "abstract";

	// ---- parameters, returns and calls

	var pLocs:Null<Placement> = null;
	var pLocsOf:Null<MFunc> = null;

	function param(i:MIns) {
		if (i.imm < 0) {
			// (the address of the struct result, MirBuild.cEntry)
			mov(reg(i.id), cc.sretReg);
			return;
		}
		if (pLocsOf != m) {
			pLocs = cc.params(m);
			pLocsOf = m;
		}
		var loc = pLocs.locs[i.imm];
		var d = reg(i.id);
		if (loc.reg >= 0) mov(d, loc.reg) else if (loc.size == 4 && i.ty == F64) {
			var g = f.newReg(false);
			var x = emit(opLoad);
			x.d = g;
			x.base = -3; // incoming stack arguments
			x.disp = loc.off;
			x.size = 4;
			f32FromBits(d, g);
		} else {
			var x = emit(opLoad);
			x.d = d;
			x.base = -3;
			x.disp = loc.off;
			x.size = loc.size;
		}
	}

	function ret(i:MIns) {
		var x = new LIns(opRet);
		if (i.a >= 0) {
			var r = cc.result(m.vals[i.a].ty == F64);
			mov(r, use(i.a), 8);
			x.uses = vector(r);
		}
		flush();
		push(x);
	}

	// a struct result in registers (MFunc.cRet), from its memory at i.a
	function structRet(i:MIns) {
		var rs = new Vector<Int>(m.cRet.length), nr = 0;
		for (p in m.cRet) {
			var r = f.newReg(p.float);
			loadPart(r, i.a, p);
			rs[nr++] = r;
		}
		var x = new LIns(opRet);
		x.uses = cc.structResult(m.cRet);
		for (k in 0...rs.length)
			mov(x.uses[k], rs[k], 8);
		flush();
		push(x);
	}

	function call(i:MIns) {
		f.hasCalls = true;
		var uses = [];
		var moves:Array<{d:Int, s:Int}> = [];
		// (a struct result: its address is the last argument, not passed when
		// it comes back in registers, else in sretReg on arm64, MirBuild.cStructRet)
		var n = i.structRet ? i.args.length - 1 : i.args.length;
		if (i.structRet && i.cRet.length == 0) {
			moves.push({d: cc.sretReg, s: i.args[n]});
			uses.push(cc.sretReg);
		}
		var pl = cc.call(i, n);
		for (k in 0...n) {
			var a = i.args[k];
			var loc = pl.locs[k];
			if (loc.bits) {
				var g = f.newReg(false);
				floatBits(g, a);
				if (loc.reg >= 0) {
					moves.push({d: loc.reg, s: -1 - g});
					uses.push(loc.reg);
				} else {
					var x = emit(opStore);
					x.base = -4; // outgoing argument area
					x.disp = loc.off;
					x.size = 8;
					x.s1 = g;
				}
				continue;
			}
			if (loc.reg >= 0) {
				moves.push({d: loc.reg, s: a});
				uses.push(loc.reg);
				if (loc.gpr >= 0) {
					var g = f.newReg(false);
					floatBits(g, a);
					moves.push({d: loc.gpr, s: -1 - g});
					uses.push(loc.gpr);
				}
				continue;
			}
			stackArg(i, k, loc);
		}
		if (pl.stack > f.outArgs) f.outArgs = pl.stack;
		var target = i.sym == null ? use(i.a) : -1;
		for (mv in moves)
			if (mv.s < 0) mov(mv.d, -1 - mv.s, 8) // (a register of this call's own: -1 - its number)
			else if (folded[mv.s]) materialize(m.vals[mv.s], mv.d) else mov(mv.d, reg(mv.s), 8);
		beforeCall(i, uses);
		var x = emit(opCall);
		x.sym = i.sym;
		x.s1 = target;
		x.uses = Vector.fromArrayCopy(uses);
		x.flag = i.returnsTwice;
		if (i.ty != Void) mov(reg(i.id), cc.result(i.ty == F64), 8);
		if (i.structRet && i.cRet.length > 0) {
			// a struct in registers: out of them first, then into its memory
			var rs = new Vector<Int>(i.cRet.length);
			var regs = cc.structResult(i.cRet);
			for (k in 0...i.cRet.length)
				rs[k] = takePart(regs[k], i.cRet[k]);
			for (k in 0...i.cRet.length)
				storePart(rs[k], i.args[n], i.cRet[k]);
		}
	}

	// d (a general register) <- the bits of the float v (a Mir value)
	function floatBits(d:Int, v:Int)
		throw "abstract";

	// d (a float register) <- the float32 in the low 32 bits of register s
	function f32FromBits(d:Int, s:Int)
		throw "abstract";

	// argument k of call i on the stack, at loc
	function stackArg(i:MIns, k:Int, loc:ArgLoc)
		throw "abstract";

	// right before the call instruction (uses: its argument registers)
	function beforeCall(i:MIns, uses:Array<Int>) {}

	// r <- part p of a struct result in registers, from its memory at addr
	function loadPart(r:Int, addr:Int, p:CAbi.CPart)
		throw "abstract";

	// part p of a struct result out of its result register into a new register
	function takePart(r:Int, p:CAbi.CPart):Int
		throw "abstract";

	// part p of a struct result from register r into its memory at addr
	function storePart(r:Int, addr:Int, p:CAbi.CPart)
		throw "abstract";
}
