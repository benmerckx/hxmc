package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Writing Mir into a function: the instruction helpers (with their peephole
// rules: constants on the right, rotations, comparisons of comparisons),
// blocks and edges, and SSA variables (Braun et al., "Simple and Efficient
// Construction of Static Single Assignment Form": a variable's value read
// where control is, phis made as reads need them). Shared by MirBuild (IR to
// object-level Mir) and MemLower (object operations to memory), so both
// write the same instructions the same way.
class MirWriter {
	var p:Prep;
	var abi:Abi;
	var fn:FuncInfo;
	var f:MFunc;
	var cur:MBlock;
	var defs:Array<BlockDefs> = []; // by block id
	var incomplete:Array<Null<Map<Int, MIns>>> = []; // (made when a block gets one)
	var varTy = new Map<Int, MTy>();
	var nextVar = 0;
	// the locals' types (MIns.vty of the phis and zeros made for them)
	var localTy = new Map<Int, Ty>();

	// (-debug) the source position of the code being written (SrcPos):
	// the instructions it adds carry it
	var curPos = 0;

	function new(p:Prep, abi:Abi, fn:FuncInfo) {
		this.p = p;
		this.abi = abi;
		this.fn = fn;
	}

	// ---- instruction helpers

	function add(i:MIns):Int {
		if (i.pos == 0) i.pos = curPos;
		i.id = f.vals.length;
		f.vals.push(i);
		i.block = cur;
		cur.ins.push(i);
		return i.id;
	}

	inline function mk(op:Op, ty:MTy):MIns
		return new MIns(op, ty);

	function op2(op:Op, ty:MTy, a:Int, b:Int):Int {
		// a commutative operation's constant on the right (the instruction
		// selections' immediate forms)
		if ((op == Add || op == Mul || op == And || op == Or || op == Xor) && f.vals[a].op == Const && f.vals[b].op != Const) {
			var t = a;
			a = b;
			b = t;
		}
		// (x >>> n) | (x << (w - n)): a rotation
		if (op == Or && (ty == I32 || ty == I64)) {
			var r = rotation(a, b, ty);
			if (r < 0) r = rotation(b, a, ty);
			if (r >= 0) return r;
			// haxe.crypto's 16-bit split addition (safeAdd, addme): an addition
			if (ty == I32) {
				r = splitAdd(a, b);
				if (r < 0) r = splitAdd(b, a);
				if (r >= 0) return r;
			}
		}
		var i = mk(op, ty);
		i.a = a;
		i.b = b;
		return add(i);
	}

	inline function isConst(v:Int, k:Int):Bool {
		var c = f.vals[v];
		return c.op == Const && c.sym == null && c.imm == k;
	}

	// a = (msw << 16), b = (lsw & 0xFFFF), lsw = (x & 0xFFFF) + (y & 0xFFFF),
	// msw = (x >> 16) + (y >> 16) + (lsw >> 16): x + y
	function splitAdd(a:Int, b:Int):Int {
		var sh = f.vals[a], lo = f.vals[b];
		if (sh.op != Shl || !isConst(sh.b, 16) || lo.op != And || lo.ty != I32) return -1;
		var lsw = -1;
		if (isConst(lo.b, 0xFFFF)) lsw = lo.a else if (isConst(lo.a, 0xFFFF)) lsw = lo.b else return -1;
		var l = f.vals[lsw];
		if (l.op != Add) return -1;
		// the operands of lsw: x & 0xFFFF, y & 0xFFFF
		function masked(v:Int):Int {
			var m = f.vals[v];
			if (m.op != And) return -1;
			return isConst(m.b, 0xFFFF) ? m.a : isConst(m.a, 0xFFFF) ? m.b : -1;
		}
		var x = masked(l.a), y = masked(l.b);
		if (x < 0 || y < 0) return -1;
		// msw: the sum, in any order, of x >> 16, y >> 16 and lsw >> 16
		var terms = [];
		function collect(v:Int, depth:Int) {
			var t = f.vals[v];
			if (t.op == Add && depth < 2) {
				collect(t.a, depth + 1);
				collect(t.b, depth + 1);
			} else terms.push(v);
		}
		collect(sh.a, 0);
		if (terms.length != 3) return -1;
		var want = [x, y, lsw];
		for (t in terms) {
			var s = f.vals[t];
			if (s.op != Sar || !isConst(s.b, 16)) return -1;
			var k = want.indexOf(s.a);
			if (k < 0) return -1;
			want.splice(k, 1);
		}
		return op2(Add, I32, x, y);
	}

	function rotation(a:Int, b:Int, ty:MTy):Int {
		var x = f.vals[a], y = f.vals[b];
		if (x.op != Shr || y.op != Shl || x.a != y.a || x.ty != ty || y.ty != ty) return -1;
		var n = f.vals[x.b], m = f.vals[y.b];
		if (n.op != Const || m.op != Const || n.sym != null || m.sym != null) return -1;
		var w = ty == I32 ? 32 : 64;
		var k = n.imm & (w - 1);
		if (k == 0 || (m.imm & (w - 1)) != w - k) return -1;
		var i = mk(Rotr, ty);
		i.a = x.a;
		i.b = iconst(k);
		return add(i);
	}

	function op1(op:Op, ty:MTy, a:Int):Int {
		// a constant widened: a constant
		var x = f.vals[a];
		if (x.op == Const && x.sym == null && x.ty == I32) {
			if (op == SExt) return lconst32(x.imm);
			if (op == ZExt) return lconst(x.imm, 0);
			if (op == I2F) return fconst(x.imm);
		}
		var i = mk(op, ty);
		i.a = a;
		return add(i);
	}

	function iconst(v:Int):Int {
		var i = mk(Const, I32);
		i.imm = v;
		return add(i);
	}

	// a program-wide number (Prep.tySym...): an absolute symbol + addend, or a plain constant
	function idConst(sym:Null<String>, value:Int, addend = 0, t:MTy = I32):Int {
		if (sym == null) return t == I32 ? iconst(value + addend) : lconst32(value + addend);
		var i = mk(Const, t);
		i.sym = sym;
		i.imm = addend;
		return add(i);
	}

	inline function tyConst(tindex:Int, addend = 0):Int
		return idConst(p.tySym(tindex), tindex, addend);

	inline function fidConst(name:String):Int
		return idConst(p.fidSym(name), 0);

	inline function sigConst(s:SigInfo):Int
		return idConst(p.sigSym(s), 0);

	function lconst(lo:Int, hi:Int):Int {
		var i = mk(Const, I64);
		i.imm = lo;
		i.imm2 = hi;
		return add(i);
	}

	inline function lconst32(v:Int):Int
		return lconst(v, v < 0 ? -1 : 0);

	function fconst(v:Float):Int {
		var i = mk(ConstF, F64);
		i.f = v;
		return add(i);
	}

	function symAddr(s:String, addend = 0):Int {
		var i = mk(SymAddr, I64);
		i.sym = s;
		i.imm = addend;
		return add(i);
	}

	function tlsLoad(s:String):Int {
		var i = mk(TlsLoad, I64);
		i.sym = s;
		return add(i);
	}

	function tlsStore(s:String, v:Int) {
		var i = mk(TlsStore, Void);
		i.sym = s;
		i.a = v;
		add(i);
	}

	// a constant index: part of the displacement
	inline function constIndex(index:Int):Bool {
		if (index < 0) return false;
		var x = f.vals[index];
		return x.op == Const && x.sym == null && x.ty == I64 && x.imm2 == (x.imm < 0 ? -1 : 0) && x.imm >= -0x1000000 && x.imm < 0x1000000;
	}

	function load(ty:MTy, size:Int, base:Int, disp:Int, signed = false, index = -1, scale = 1):Int {
		if (constIndex(index)) {
			disp += f.vals[index].imm * scale;
			index = -1;
		}
		var i = mk(Load, ty);
		i.mem = memCls;
		i.a = base;
		i.b = index;
		i.imm = disp;
		i.imm2 = scale;
		i.size = size;
		i.signed = signed;
		return add(i);
	}

	// the memory class of the loads and stores made (Opt.MOther...)
	var memCls = 0;

	function loadM(cls:Int, ty:MTy, size:Int, base:Int, disp:Int, signed = false, index = -1, scale = 1):Int {
		memCls = cls;
		var r = load(ty, size, base, disp, signed, index, scale);
		memCls = 0;
		return r;
	}

	function storeM(cls:Int, size:Int, base:Int, disp:Int, v:Int, index = -1, scale = 1, release = false) {
		memCls = cls;
		store(size, base, disp, v, index, scale, release);
		memCls = 0;
	}

	function store(size:Int, base:Int, disp:Int, v:Int, index = -1, scale = 1, release = false) {
		if (constIndex(index)) {
			disp += f.vals[index].imm * scale;
			index = -1;
		}
		var i = mk(Store, Void);
		i.mem = memCls;
		i.a = base;
		i.b = index;
		i.c = v;
		i.imm = disp;
		i.imm2 = scale;
		i.size = size;
		i.release = release;
		add(i);
	}

	function cmp(c:Cond, a:Int, b:Int):Int {
		// (x op y) == 0 is the inverse comparison, (x op y) != 0 the same one
		// (the inner comparison is left unused: instruction selection drops it)
		var x = f.vals[a], z = f.vals[b];
		if ((c == CEq || c == CNe) && x.op == Cmp && z.op == Const && z.imm == 0) {
			var inner:Cond = x.imm;
			if (c == CNe) return cmp(inner, x.a, x.b);
			var inv = invert(inner);
			if (inv >= 0) return cmp(inv, x.a, x.b);
		}
		var i = mk(Cmp, I32);
		i.imm = c;
		i.a = a;
		i.b = b;
		return add(i);
	}

	// the comparison true exactly when c is false, or -1 (ordered double
	// comparisons are false with NaN either way)
	static function invert(c:Cond):Int {
		return switch c {
			case CEq: CNe;
			case CNe: CEq;
			case CLt: CGe;
			case CGe: CLt;
			case CLe: CGt;
			case CGt: CLe;
			case CULt: CUGe;
			case CUGe: CULt;
			case CULe: CUGt;
			case CUGt: CULe;
			case FEq: FNe;
			case FNe: FEq;
			case _: -1;
		}
	}

	function tyOfVal(v:Int):MTy
		return f.vals[v].ty;

	// whether nothing collects during a call of sym (in this function): a
	// function of the program that never reaches a GC point nor enters a
	// safe region, or such a C function, unless this function is in a
	// safe region itself (another thread may collect meanwhile). The root
	// slots then keep their values across the call (Opt: MIns.keepsFrame).
	function keepsFrame(sym:String):Bool
		return p != null && fn != null && !f.blocksHere && keepsFrameOf(sym, p.e.bySymbol.get(sym));

	// (g: the program's function of that symbol, or null)
	function keepsFrameOf(sym:String, g:Null<FuncInfo>):Bool {
		if (p == null || fn == null || f.blocksHere) return false;
		if (g != null) return g.noGc && !g.blocks;
		if (sym == "rt_blocking_enter" || sym == "rt_blocking_leave") return false;
		return hxmc.ir.FnLower.noGcHost(sym) || QUIET.exists(sym) || StringTools.startsWith(sym, "hxmc$");
	}

	// C functions that neither collect nor wait in a safe region, besides
	// the runtime functions FnLower.noGcHost names
	static var QUIET = [
		"hxmc_zero" => true, "memset" => true, "memcpy" => true, "memmove" => true, "floor" => true, "ceil" => true,
		"hxmc_barrier_slow" => true, "setjmp" => true, "_setjmp" => true, "__mingw_setjmp" => true, "hxmc_tls_base" => true,
	];

	function call(sym:String, args:Vector<Int>, ret:MTy, noReturn = false):Int {
		var g = p == null ? null : p.e.bySymbol.get(sym);
		// (a function the runtime exports, called by its symbol: one hxmc.ir.RuntimeSymbols lists)
		if (g != null && g.cSymbol == sym) {
			var family = abi.wasm ? hxmc.ir.RuntimeSymbols.WASM32 : hxmc.ir.RuntimeSymbols.NATIVE;
			if (g.rtFamilies & family == 0) hxmc.ir.RuntimeSymbols.called(sym, family);
		}
		var i = mk(Call, ret);
		i.sym = sym;
		i.keepsFrame = keepsFrameOf(sym, g);
		i.args = args;
		i.argTys = args.map(tyOfVal);
		i.noReturn = noReturn;
		return add(i);
	}

	function callInd(fnv:Int, args:Vector<Int>, ret:MTy, ?argTys:Vector<MTy>):Int {
		var i = mk(Call, ret);
		i.a = fnv;
		i.args = args;
		i.argTys = argTys != null ? argTys : args.map(tyOfVal);
		return add(i);
	}

	// an inline expansion the instruction selection does (Call to hxmc$...)
	function special(name:String, args:Vector<Int>, ret:MTy):Int
		return call(MirBuild.SPECIAL + name, args, ret);

	function stackAddr(slot:Int):Int {
		var i = mk(StackAddr, I64);
		i.imm = slot;
		return add(i);
	}

	// ---- blocks

	// blocks made while set are slow paths (the inline-cache path behind a
	// shape hint: unlikely)
	var coldNew = false;

	function newBlock():MBlock {
		var b = f.newBlock();
		if (coldNew) b.cold = true;
		defs.push(new BlockDefs());
		incomplete.push(null);
		return b;
	}

	function edge(from:MBlock, to:MBlock) {
		from.succs.push(to);
		to.preds.push(from);
	}

	inline function terminated():Bool
		return cur.term() != null;

	function jmp(to:MBlock) {
		if (terminated()) return;
		var i = mk(Jmp, Void);
		i.targets = vector(to);
		add(i);
		edge(cur, to);
	}

	function br(c:Int, t:MBlock, e:MBlock) {
		var i = mk(Br, Void);
		i.a = c;
		i.targets = vector(t, e);
		add(i);
		edge(cur, t);
		edge(cur, e);
	}

	// ---- SSA variables (locals by id; temporaries above)

	function newVar(t:MTy):Int {
		var v = nextVar++;
		varTy.set(v, t);
		return v;
	}

	function writeVar(v:Int, b:MBlock, val:Int)
		defs[b.id].set(v, val);

	function readVar(v:Int, b:MBlock):Int {
		var d = defs[b.id].get(v);
		if (d != null) return d == VISITING ? cyclePhi(v, b) : d;
		return readVarRec(v, b);
	}

	// (readVarRec: the predecessors of a block being read)
	static inline var VISITING = -2;

	// a read that came back to a block whose predecessors are being read:
	// the phi there (its operands are those reads)
	function cyclePhi(v:Int, b:MBlock):Int {
		var phi = newPhi(b, varTy.get(v));
		defs[b.id].set(v, phi.id);
		return phi.id;
	}

	function newPhi(b:MBlock, t:MTy):MIns {
		var i = mk(Phi, t);
		i.id = f.vals.length;
		f.vals.push(i);
		i.block = b;
		var k = 0;
		while (k < b.ins.length && b.ins[k].op == Phi)
			k++;
		b.ins.insert(k, i);
		return i;
	}

	function readVarRec(v:Int, b:MBlock):Int {
		var t = varTy.get(v);
		var val:Int;
		if (!b.sealed) {
			var phi = newPhi(b, t);
			var inc = incomplete[b.id];
			if (inc == null) incomplete[b.id] = inc = new Map();
			inc.set(v, phi);
			val = phi.id;
		} else if (b.preds.length == 0) {
			// never assigned (C: the local starts as 0)
			val = zeroAt(b, t);
		} else if (b.preds.length == 1 && !merges(v, b)) {
			val = readVar(v, b.preds[0]);
		} else if (!merges(v, b)) {
			// the predecessors' values: a phi only where they differ, or where
			// a read came back here (Braun et al.'s marker: no trivial phi
			// made at a join the variable reaches unchanged)
			defs[b.id].set(v, VISITING);
			var args = readVars(v, b);
			var d = defs[b.id].get(v);
			if (d != VISITING) {
				f.vals[d].args = args;
				val = d;
			} else {
				val = args[0];
				for (x in args)
					if (x != val) {
						val = -1;
						break;
					}
				if (val < 0) {
					var phi = newPhi(b, t);
					phi.args = args;
					val = phi.id;
				}
			}
		} else {
			var phi = newPhi(b, t);
			phiMade(v, b, phi);
			writeVar(v, b, phi.id);
			phi.args = readVars(v, b);
			val = phi.id;
		}
		writeVar(v, b, val);
		var x = f.vals[val];
		if (x.vty == null) x.vty = localTy.get(v);
		return val;
	}

	// whether variable v gets a phi in b of one predecessor (MirBuild: a
	// reference a cold site reads back, in the continuation its lowering
	// reaches by several edges)
	function merges(v:Int, b:MBlock):Bool
		return false;

	function phiMade(v:Int, b:MBlock, phi:MIns) {}

	// a zero constant at the start of b (after its phis)
	function zeroAt(b:MBlock, t:MTy):Int {
		var i = t == F64 ? mk(ConstF, F64) : mk(Const, t == Void ? I32 : t);
		i.id = f.vals.length;
		f.vals.push(i);
		i.block = b;
		var k = 0;
		while (k < b.ins.length && b.ins[k].op == Phi)
			k++;
		b.ins.insert(k, i);
		return i.id;
	}

	function seal(b:MBlock) {
		if (b.sealed) return;
		b.sealed = true;
		var inc = incomplete[b.id];
		if (inc == null) return;
		for (v => phi in inc)
			phi.args = readVars(v, b);
		incomplete[b.id] = null;
	}

	// a phi's arguments: v at the end of each pred of b
	function readVars(v:Int, b:MBlock):Vector<Int> {
		var args = new Vector<Int>(b.preds.length);
		for (k in 0...args.length)
			args[k] = readVar(v, b.preds[k]);
		return args;
	}

	// ---- shared runtime details

	// rt_sp_hw = max(rt_sp_hw, top): rarely raised (after a collection), on a slow path;
	// on WebAssembly also where the shadow stack overflows (past rt_sp_limit: a
	// region of linear memory, no guard page; every new depth passes here first)
	function raiseHw(top:Int) {
		var hw = tlsLoad("rt_sp_hw");
		var up = newBlock(), done = newBlock();
		up.cold = true;
		br(cmp(CUGt, top, hw), up, done);
		seal(up);
		cur = up;
		if (abi.wasm) {
			var over = newBlock(), fits = newBlock();
			over.cold = true;
			fits.cold = true;
			br(cmp(CUGt, top, loadM(Opt.MCallOnly, I64, 8, symAddr("rt_sp_limit"), 0)), over, fits);
			seal(over);
			cur = over;
			call("rt_stack_overflow", vector(), Void, true);
			add(mk(Unreachable, Void));
			seal(fits);
			cur = fits;
		}
		tlsStore("rt_sp_hw", top);
		jmp(done);
		seal(done);
		cur = done;
	}

	// an array's first header word: its type t, its words (0xFFFF from that
	// many on, without a branch: hxmc.rt.Types.arrWord)
	function arrWord(t:Int, words:Int):Int {
		var sat = op2(Sar, I32, op2(Sub, I32, iconst(0xFFFE), words), iconst(31));
		return op2(Or, I32, t, op2(Shl, I32, op2(Or, I32, words, sat), iconst(16)));
	}
}

// the values of SSA variables at the end of a block (Braun et al.'s
// currentDef for one block): few entries, a linear list
class BlockDefs {
	var keys:Array<Int> = [];
	var vals:Array<Int> = [];

	public function new() {}

	public function get(v:Int):Null<Int> {
		var k = keys.length;
		while (k-- > 0)
			if (keys[k] == v) return vals[k];
		return null;
	}

	public function set(v:Int, val:Int) {
		var k = keys.length;
		while (k-- > 0)
			if (keys[k] == v) {
				vals[k] = val;
				return;
			}
		keys.push(v);
		vals.push(val);
	}
}
