package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.ir.CInterop.CTy;

// hxmc's IR (hxmc.ir.Ir: structured statements in A-normal form) of one
// function to Mir (the runtime's inline helpers are expanded here,
// so the native code and the runtime agree on every detail):
// - reference locals that Roots puts in shadow-stack slots live in memory
//   (fr[k]); in functions with a try block the locals a handler can see
//   live in memory, so values survive the second return of setjmp; the other
//   locals become SSA values (Braun et al., "Simple and Efficient
//   Construction of Static Single Assignment Form", on the structured input);
// - cold sites (SCold) root the references live across them only on the
//   slow path of the allocation or array store.
// Constructs not handled throw Unsupported (the build fails).
class MirBuild {
	var p:Prep;
	var abi:Abi;
	var fn:FuncInfo;
	var f:MFunc;
	var cur:MBlock;
	var roots:Roots;
	var refSlot = new Map<Local, Int>();
	var nslots = 0;
	var fr = -1; // the frame's shadow-stack slots (value)
	var memSlot = new Map<Local, Int>(); // try functions: frame slot of a scalar local
	var defs:Array<BlockDefs> = [];
	var incomplete:Array<Null<Map<Int, MIns>>> = []; // (made when a block gets one)
	var varTy = new Map<Int, MTy>();
	var nextVar = 0;
	var loops:Array<{cont:MBlock, brk:MBlock, tries:Int}> = [];
	var tries:Array<Int> = []; // frame slots of the enclosing handlers
	var coldList:Null<Array<Local>> = null;
	// the functions that may be inlined (Inline.candidate; set once, read by the threads)
	public static var inlineCands:Null<Map<FuncInfo, Bool>>;
	// the calls of this function to them
	public var inlineSites:Array<{call:MIns, fn:FuncInfo}> = [];
	public var frameSlots(get, never):Int;

	inline function get_frameSlots()
		return nslots;

	static var noShadow = Sys.getEnv("HXMC_NOSHADOW") == "1";
	static var frameSpills = Sys.getEnv("HXMC_FRAMESPILL") != "0"; // (measurement: 0 pushes on every slow path)

	public var icaches = 0; // inline caches of this function (bss: <name>__ic, IC_SIZE each)
	public var icSym:String;

	public function new(p:Prep, abi:Abi, fn:FuncInfo) {
		this.p = p;
		this.abi = abi;
		this.fn = fn;
	}

	public static function mty(t:Ty):MTy
		return switch t {
			case TI32 | TBool: I32;
			case TF64: F64;
			case TI64: I64;
			case TVoid: Void;
			case TRef(_) | TStruct(_): I64;
		};

	// ---- instruction helpers

	// (-debug) the source position of the statement being built (SrcPos):
	// the instructions it adds carry it
	var curPos = 0;

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

	// the address of rt_globals[g]
	function globalAddr(g:Int):Int
		return op2(Add, I64, loadM(Opt.MConst, I64, 8, symAddr("rt_globals"), 0), idConst(p.globalOffSym(g), 0, 0, I64));

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

	// the symbol of a @:hxmc.threadLocal static (8 bytes per thread), or null
	// (WebAssembly: one thread, an ordinary global)
	function tlsGlobal(g:Int):Null<String>
		return abi.wasm ? null : p.p.globals[g].tls;

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

	function storeM(cls:Int, size:Int, base:Int, disp:Int, v:Int, index = -1, scale = 1) {
		memCls = cls;
		store(size, base, disp, v, index, scale);
		memCls = 0;
	}

	function store(size:Int, base:Int, disp:Int, v:Int, index = -1, scale = 1) {
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
	function keepsFrame(sym:String):Bool {
		if (p == null || fn == null || fn.blocksHere) return false;
		var g = p.e.bySymbol.get(sym);
		if (g != null) return g.noGc && !g.blocks;
		if (sym == "rt_blocking_enter" || sym == "rt_blocking_leave") return false;
		return hxmc.ir.FnLower.noGcHost(sym) || QUIET.exists(sym) || StringTools.startsWith(sym, "hxmc$");
	}

	// C functions that neither collect nor wait in a safe region, besides
	// the runtime functions FnLower.noGcHost names
	// the runtime's machine-code stubs (Target.Emitter.stub)
	public static inline var STUB_CALL_ON_STACK = "hxmc_call_on_stack";
	public static inline var STUB_ZERO = "hxmc_zero";
	public static inline var STUB_FRAME = "hxmc_frame";

	static var QUIET = [
		"hxmc_zero" => true, "memset" => true, "memcpy" => true, "memmove" => true, "floor" => true, "ceil" => true,
		"hxmc_barrier_slow" => true, "setjmp" => true, "_setjmp" => true, "__mingw_setjmp" => true, "hxmc_tls_base" => true,
	];

	function call(sym:String, args:Array<Int>, ret:MTy, noReturn = false):Int {
		var i = mk(Call, ret);
		i.sym = sym;
		i.keepsFrame = keepsFrame(sym);
		i.args = args;
		i.argTys = [for (a in args) tyOfVal(a)];
		i.noReturn = noReturn;
		return add(i);
	}

	function callInd(fnv:Int, args:Array<Int>, ret:MTy, ?argTys:Array<MTy>):Int {
		var i = mk(Call, ret);
		i.a = fnv;
		i.args = args;
		i.argTys = argTys != null ? argTys : [for (a in args) tyOfVal(a)];
		return add(i);
	}

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
		i.targets = [to];
		add(i);
		edge(cur, to);
	}

	function br(c:Int, t:MBlock, e:MBlock) {
		var i = mk(Br, Void);
		i.a = c;
		i.targets = [t, e];
		add(i);
		edge(cur, t);
		edge(cur, e);
	}

	// a new block reached only from where control is now
	function split():MBlock {
		var b = newBlock();
		jmp(b);
		seal(b);
		cur = b;
		return b;
	}

	// statements after a return/break/throw: an unreachable block of their own
	function deadBlock() {
		var b = newBlock();
		seal(b);
		cur = b;
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
		if (d != null) return d;
		return readVarRec(v, b);
	}

	function newPhi(b:MBlock, t:MTy):MIns {
		var i = mk(Phi, t);
		i.args = [];
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
		} else if (b.preds.length == 1) {
			val = readVar(v, b.preds[0]);
		} else {
			var phi = newPhi(b, t);
			writeVar(v, b, phi.id);
			for (pr in b.preds)
				phi.args.push(readVar(v, pr));
			val = phi.id;
		}
		writeVar(v, b, val);
		return val;
	}

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
			for (pr in b.preds)
				phi.args.push(readVar(v, pr));
		incomplete[b.id] = null;
	}

	// ---- locals

	public static function assignedInTry(fn:FuncInfo):Map<Int, Bool> {
		var out = new Map<Int, Bool>();
		var depth = 0;
		function ex(e:Ex) {}
		function st(s:Stmt) {
			switch s {
				case SSet(l, _) if (depth > 0):
					out.set(l.id, true);
				case STry(body, catches):
					depth++;
					for (x in body)
						st(x);
					depth--;
					for (c in catches) {
						if (depth > 0) out.set(c.l.id, true);
						for (x in c.body)
							st(x);
					}
					return;
				case _:
			}
			hxmc.ir.Facts.iterStmt(st, ex, s);
		}
		for (s in fn.body)
			st(s);
		return out;
	}

	// try functions: the scalar locals kept in memory: assigned inside a try
	// body and referenced outside it, where a second return of setjmp (the
	// handler, what follows the try, the next iteration around it) finds
	// their latest value. A local all of whose
	// references are inside the try body that assigns it is dead there (a
	// local declared in the body is assigned before it is read).
	public static function memLocals(fn:FuncInfo):Map<Int, Bool> {
		var path:Array<Int> = []; // the try bodies around, outermost first
		var nextTry = 0;
		var common = new Map<Int, Array<Int>>(); // per local: the try bodies around all its references
		var deepest = new Map<Int, Int>(); // per local: the most try bodies around one of its assignments
		function ref(id:Int) {
			var c = common.get(id);
			if (c == null) {
				common.set(id, path.copy());
				return;
			}
			var k = 0;
			while (k < c.length && k < path.length && c[k] == path[k])
				k++;
			if (k < c.length) c.resize(k);
		}
		function assign(id:Int) {
			ref(id);
			var d = deepest.get(id);
			if (d == null || path.length > d) deepest.set(id, path.length);
		}
		function ex(e:Ex) {
			switch e {
				case ELocal(l): ref(l.id);
				case _:
			}
			hxmc.ir.Facts.iterEx(ex, e);
		}
		function st(s:Stmt) {
			switch s {
				case SSet(l, e):
					ex(e);
					assign(l.id);
					return;
				case SArrSet(_, a, _, _) | SArrPush(_, a, _):
					ref(a.id);
				case STry(body, catches):
					path.push(nextTry++);
					for (x in body)
						st(x);
					path.pop();
					for (c in catches) {
						assign(c.l.id);
						if (c.test != null) ex(c.test(ELocal(c.l)));
						for (x in c.body)
							st(x);
					}
					return;
				case _:
			}
			hxmc.ir.Facts.iterStmt(st, ex, s);
		}
		for (a in fn.args)
			assign(a.id);
		for (s in fn.body)
			st(s);
		var out = new Map<Int, Bool>();
		for (id => d in deepest)
			if (d > common.get(id).length) out.set(id, true);
		return out;
	}

	function readLocal(l:Local):Int {
		var s = refSlot.get(l);
		if (s != null) return loadM(Opt.MFrame, I64, 8, fr, 8 * s);
		var m = memSlot.get(l);
		if (m != null) {
			var t = mty(l.ty);
			var a = stackAddr(m);
			return load(t, t == I32 ? 4 : 8, a, 0);
		}
		return readVar(l.id, cur);
	}

	function writeLocal(l:Local, v:Int) {
		var s = refSlot.get(l);
		if (s != null) {
			storeM(Opt.MFrame, 8, fr, 8 * s, v);
			return;
		}
		var m = memSlot.get(l);
		if (m != null) {
			var t = mty(l.ty);
			store(t == I32 ? 4 : 8, stackAddr(m), 0, v);
			return;
		}
		writeVar(l.id, cur, v);
	}

	function stackAddr(slot:Int):Int {
		var i = mk(StackAddr, I64);
		i.imm = slot;
		return add(i);
	}

	// ---- entry

	// a function made up by hxmc (closure trampolines, main): `body` uses the
	// instruction helpers (@:access) and must end every path with a return
	public static function synthetic(p:Prep, abi:Abi, name:String, params:Array<MTy>, ret:MTy, body:(MirBuild, Array<Int>) -> Void):MFunc {
		var mb = new MirBuild(p, abi, null);
		var f = mb.f = new MFunc(name);
		f.params = params;
		f.ret = ret;
		var entry = mb.newBlock();
		f.entry = entry;
		mb.seal(entry);
		mb.cur = entry;
		var ps = [];
		for (i in 0...params.length) {
			var pi = mb.mk(Param, params[i]);
			pi.imm = i;
			ps.push(mb.add(pi));
		}
		body(mb, ps);
		for (b in f.blocks)
			if (!b.sealed) mb.seal(b);
		mb.prune();
		mb.removeTrivialPhis();
		return f;
	}

	public function build():MFunc {
		f = new MFunc(p.funcSym(fn));
		f.blocksHere = fn.blocksHere;
		for (a in fn.args)
			f.params.push(mty(a.ty));
		f.ret = mty(fn.ret);
		var maxId = 0;
		for (l in fn.args.concat(fn.locals)) {
			if (l.id >= maxId) maxId = l.id + 1;
			varTy.set(l.id, mty(l.ty) == Void ? I32 : mty(l.ty));
		}
		nextVar = maxId;
		roots = Roots.analyze(fn);
		// the frame's slots: the rooted locals' (shared by locals that never
		// live at the same time, Roots.assign), those that may be read
		// unassigned last (zeroed, unshared; in a try function, a handler may
		// read what its body had not assigned yet when it threw)
		var all = fn.args.concat(fn.locals);
		var unset = Roots.maybeUnset(fn);
		var a = roots.assign(all, unset, unset);
		for (l in all) {
			var k = a.slotOf.get(l.id);
			if (k != null) refSlot.set(l, k);
		}
		nslots = a.nslots;
		var zeroFrom = a.nslots - a.nzero;
		// measurement only (HXMC_NOSHADOW=1): no shadow-stack frames, references in
		// SSA values; correct only while nothing collects (the cost of the frames)
		if (noShadow && !fn.hasTry) {
			refSlot = new Map();
			nslots = 0;
		}
		// a function with a frame keeps the references its slow paths spill
		// in slots of its own after its locals' (no push and pop on the slow
		// paths); one without one pushes them there
		if (nslots > 0 && !noShadow && frameSpills) {
			var most = hasArrayStore(fn.body) ? 1 : 0; // (an array store's value: one more)
			for (list in roots.spills) {
				var n = 1;
				for (l in list)
					if (!refSlot.exists(l)) n++;
				if (n > most) most = n;
			}
			spillBase = nslots;
			nslots += most;
		}
		var entry = newBlock();
		f.entry = entry;
		seal(entry);
		cur = entry;
		var params = [];
		if (fn.cAbi != null) params = cEntry() else
			for (i in 0...fn.args.length) {
				var pi = mk(Param, f.params[i]);
				pi.imm = i;
				params.push(add(pi));
			}
		if (nslots > 0) {
			fr = push(nslots);
			// (the other slots hold null or a valid reference already: rt_sp_hw)
			if (zeroFrom < a.nslots) {
				var z = lconst(0, 0);
				for (k in zeroFrom...a.nslots)
					store(8, fr, 8 * k, z);
			}
		}
		// try functions: the scalars memLocals finds live in memory; the
		// others are SSA values, which are immutable (in a slot or a
		// callee-saved register across setjmp, both as they were at the call)
		if (fn.hasTry) {
			var inMem = Sys.getEnv("HXMC_TRYMEM") == "all" ? assignedInTry(fn) : memLocals(fn);
			for (l in fn.args.concat(fn.locals))
				if (!refSlot.exists(l) && inMem.exists(l.id)) memSlot.set(l, f.slot(8, 8));
		}
		for (i in 0...fn.args.length)
			writeLocal(fn.args[i], params[i]);
		if (fn.hasTry)
			for (l in fn.locals)
				if (memSlot.exists(l)) {
					var t = mty(l.ty);
					writeLocal(l, t == F64 ? fconst(0) : t == I64 ? lconst(0, 0) : iconst(0));
				}
		stmts(fn.body);
		if (!terminated()) {
			popFrame();
			if (f.ret == Void) ret(-1) else ret(f.ret == F64 ? fconst(0) : f.ret == I64 ? lconst(0, 0) : iconst(0));
		}
		if (retBlock != null) {
			seal(retBlock);
			cur = retBlock;
			popFrame();
			ret(f.ret == Void ? -1 : readVar(retVar, cur));
		}
		for (b in f.blocks)
			if (!b.sealed) seal(b);
		prune();
		removeTrivialPhis();
		return f;
	}

	// drops the blocks not reachable from the entry (and their phi operands)
	function prune() {
		var reach = f.newMark();
		var stack = [f.entry];
		f.entry.mark = reach;
		while (stack.length > 0) {
			var b = stack.pop();
			for (s in b.succs)
				if (s.mark != reach) {
					s.mark = reach;
					stack.push(s);
				}
		}
		var all = true;
		for (b in f.blocks) {
			if (b.mark == reach) continue;
			all = false;
			for (s in b.succs) {
				var k = s.preds.indexOf(b);
				if (k < 0) continue;
				s.preds.splice(k, 1);
				for (i in s.ins)
					if (i.op == Phi) i.args.splice(k, 1);
			}
		}
		if (!all) f.blocks = [for (b in f.blocks) if (b.mark == reach) b];
	}

	function ret(v:Int) {
		var i = mk(Ret, Void);
		i.a = v;
		add(i);
	}

	// rt_push(n): the frame's slots on the shadow stack
	function push(n:Int):Int {
		var sp = tlsLoad("rt_sp");
		var top = op2(Add, I64, sp, lconst32(8 * n));
		tlsStore("rt_sp", top);
		raiseHw(top);
		return sp;
	}

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
			call("rt_stack_overflow", [], Void, true);
			add(mk(Unreachable, Void));
			seal(fits);
			cur = fits;
		}
		tlsStore("rt_sp_hw", top);
		jmp(done);
		seal(done);
		cur = done;
	}

	// a function with a frame returns through one block (one pop of the
	// frame, one epilogue)
	var retBlock:Null<MBlock> = null;
	var retVar = -1;

	function retFrom(v:Int) {
		if (nslots == 0) {
			ret(v);
			return;
		}
		if (retBlock == null) {
			retBlock = newBlock();
			retBlock.cold = false;
			if (f.ret != Void) retVar = newVar(f.ret);
		}
		if (v >= 0) writeVar(retVar, cur, v);
		jmp(retBlock);
	}

	function popFrame() {
		if (nslots > 0) tlsStore("rt_sp", fr);
	}

	// replaces phis whose operands are one value (or the phi itself), until none is left
	function removeTrivialPhis() {
		var repl:Null<haxe.ds.Vector<Int>> = null; // phi -> its value (-1: none)
		inline function find(v:Int):Int {
			if (repl != null)
				while (v < repl.length && repl[v] >= 0)
					v = repl[v];
			return v;
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (b in f.blocks)
				for (i in b.ins) {
					if (i.op != Phi || i.dead) continue;
					var same = -1;
					var trivial = true;
					for (a in i.args) {
						var x = find(a);
						if (x == i.id || x == same) continue;
						if (same >= 0) {
							trivial = false;
							break;
						}
						same = x;
					}
					if (trivial && same >= 0) {
						if (repl == null) repl = MFunc.ints(f.vals.length, -1);
						repl[i.id] = same;
						i.dead = true;
						changed = true;
					}
				}
		}
		if (repl == null) return;
		for (b in f.blocks) {
			var ins = b.ins, k = 0;
			for (i in ins)
				if (!i.dead) ins[k++] = i;
			if (k < ins.length) ins.resize(k);
			for (i in ins) {
				if (i.a >= 0) i.a = find(i.a);
				if (i.b >= 0) i.b = find(i.b);
				if (i.c >= 0) i.c = find(i.c);
				if (i.args != null)
					for (k in 0...i.args.length)
						i.args[k] = find(i.args[k]);
			}
		}
	}

	// ---- statements

	function stmts(ss:Array<Stmt>) {
		// (a nested list's positions end with it: the code after it, or another
		// branch, has the position it had before)
		var saved = curPos;
		for (s in ss) {
			switch s {
				case SPos(file, line):
					curPos = SrcPos.id(file, line);
					continue;
				case _:
			}
			if (terminated()) deadBlock();
			stmt(s);
		}
		curPos = saved;
	}

	function stmt(s:Stmt) {
		switch s {
			case SCold(id, x):
				var list = roots.spills.get(id);
				coldList = list == null ? [] : [for (l in list) if (!refSlot.exists(l)) l];
				coldStmt(x);
				coldList = null;
			case SSet(l, e):
				writeLocal(l, ex(e));
			case SExpr(e):
				ex(e);
			case SSetField(c, idx, obj, v):
				var o = ex(obj);
				var x = ex(v);
				storeSlot(o, c.locs[idx], c.fields[idx].ty, x, isNullConst(v));
			case SBoxSet(t, bx, v):
				var o = ex(bx);
				var x = ex(v);
				storeSlot(o, 0, t, x, isNullConst(v));
			case SSetGlobal(g, _) if (p.p.globals[g].bss != null):
				throw new Unsupported("a @:hxmc.bss static is constant (" + p.p.globals[g].name + ")");
			case SSetGlobal(g, v) if (tlsGlobal(g) != null):
				var x = ex(v);
				var t = p.p.globals[g].ty;
				tlsStore(tlsGlobal(g), t == TF64 ? op1(FToBits, I64, x) : t == TI64 ? x : op1(SExt, I64, x));
			case SSetGlobal(g, v):
				var x = ex(v);
				var t = p.p.globals[g].ty;
				if (Ir.isRef(t)) {
					storeM(Opt.MGlobal, 8, globalAddr(g), 0, x);
				} else storeM(Opt.MGlobal, t == TI32 || t == TBool ? 4 : 8, symAddr(p.scalarGlobalSym(g)), 0, x);
			case SAnonSet(name, t, obj, v):
				anonSet(name, t, obj, v);
			case SArrSet(elem, a, i, v):
				arrSet(elem, a, i, v, false);
			case SArrPush(elem, a, v):
				arrPush(elem, a, v, false);
			case SIf(c, x, y):
				var cv = ex(c);
				var t = newBlock(), e = y.length > 0 ? newBlock() : null, join = newBlock();
				br(cv, t, y.length > 0 ? e : join);
				seal(t);
				cur = t;
				stmts(x);
				jmp(join);
				if (y.length > 0) {
					seal(e);
					cur = e;
					stmts(y);
					jmp(join);
				}
				seal(join);
				cur = join;
				if (join.preds.length == 0) {
					var i = mk(Unreachable, Void);
					add(i);
				}
			case SLoop(body):
				var head = newBlock(), exit = newBlock();
				jmp(head);
				cur = head;
				loops.push({cont: head, brk: exit, tries: tries.length});
				stmts(body);
				jmp(head);
				loops.pop();
				seal(head);
				seal(exit);
				cur = exit;
				if (exit.preds.length == 0) add(mk(Unreachable, Void));
			case SBreak:
				var lp = loops[loops.length - 1];
				unwindTo(lp.tries);
				jmp(lp.brk);
			case SContinue:
				var lp = loops[loops.length - 1];
				unwindTo(lp.tries);
				jmp(lp.cont);
			case SSwitch(e, cases, def):
				var v = ex(e);
				var seen = new Map<Int, Bool>();
				var join = newBlock();
				var vals = [], targets = [], bodies = [];
				for (c in cases) {
					var labels = [for (x in c.values) if (!seen.exists(x)) x];
					for (x in labels)
						seen.set(x, true);
					if (labels.length == 0) continue;
					var b = newBlock();
					bodies.push({b: b, body: c.body});
					for (x in labels) {
						vals.push(x);
						targets.push(b);
					}
				}
				var db = newBlock();
				switchTree(v, vals, targets, db);
				for (x in bodies) {
					seal(x.b);
					cur = x.b;
					stmts(x.body);
					jmp(join);
				}
				seal(db);
				cur = db;
				stmts(def);
				jmp(join);
				seal(join);
				cur = join;
				if (join.preds.length == 0) add(mk(Unreachable, Void));
			case SReturn(null):
				unwindTo(0);
				retFrom(-1);
			case SReturn(e) if (cSret >= 0):
				// (a callback's struct result, through the memory its caller gave)
				var v = ex(e);
				copyBytes(cSret, v, cSretSize);
				unwindTo(0);
				retFrom(f.ret == Void ? -1 : cSret);
			case SReturn(e):
				var v = ex(e);
				unwindTo(0);
				retFrom(v);
			case SThrow(e):
				var v = ex(e);
				call("rt_throw", [v], Void, true);
				add(mk(Unreachable, Void));
			case STry(body, catches):
				tryStmt(body, catches);
			case SPos(file, line):
				curPos = SrcPos.id(file, line);
		}
	}

	// RT_POP of the handler at `depth` (the outermost one left)
	function unwindTo(depth:Int) {
		if (tries.length > depth) {
			var h = stackAddr(tries[depth]);
			tlsStore("rt_hcur", load(I64, 8, h, abi.handlerPrev));
		}
	}

	function tryStmt(body:Array<Stmt>, catches:Array<{test:Null<Ex->Ex>, l:Local, body:Array<Stmt>}>) {
		var slot = f.slot(abi.handlerSize, abi.handlerAlign < 16 ? 16 : abi.handlerAlign);
		var h = stackAddr(slot);
		store(8, h, abi.handlerPrev, tlsLoad("rt_hcur"));
		store(8, h, abi.handlerSp, tlsLoad("rt_sp"));
		tlsStore("rt_hcur", h);
		var sj = mk(Call, I32);
		sj.sym = abi.setjmp;
		sj.args = abi.os == "windows" && !abi.arm ? [h, lconst(0, 0)] : [h];
		sj.argTys = [for (_ in sj.args) I64];
		sj.returnsTwice = true;
		var r = add(sj);
		var tb = newBlock(), hb = newBlock(), join = newBlock();
		hb.handler = true;
		br(cmp(CEq, r, iconst(0)), tb, hb);
		seal(tb);
		seal(hb);
		cur = tb;
		tries.push(slot);
		stmts(body);
		tries.pop();
		if (!terminated()) {
			var h2 = stackAddr(slot);
			tlsStore("rt_hcur", load(I64, 8, h2, abi.handlerPrev));
			jmp(join);
		}
		cur = hb;
		var h3 = stackAddr(slot);
		tlsStore("rt_hcur", load(I64, 8, h3, abi.handlerPrev));
		tlsStore("rt_sp", load(I64, 8, h3, abi.handlerSp));
		var exn = tlsLoad("rt_exn");
		for (c in catches)
			writeLocal(c.l, exn);
		tlsStore("rt_exn", lconst(0, 0));
		var catchAll = false;
		for (c in catches) {
			if (c.test == null) {
				stmts(c.body);
				jmp(join);
				catchAll = true;
				break;
			}
			var t = ex(c.test(ELocal(c.l)));
			var yes = newBlock(), no = newBlock();
			br(t, yes, no);
			seal(yes);
			seal(no);
			cur = yes;
			stmts(c.body);
			jmp(join);
			cur = no;
		}
		if (!catchAll) {
			call("rt_throw", [readLocal(catches[0].l)], Void, true);
			add(mk(Unreachable, Void));
		}
		seal(join);
		cur = join;
		if (join.preds.length == 0) add(mk(Unreachable, Void));
	}

	static function isNullConst(e:Ex):Bool
		return e.match(ENull(_));

	// ---- object slots

	function slotLoad(o:Int, loc:Int, t:Ty):Int
		return switch t {
			case TRef(_): loadM(Opt.MField, I64, 8, o, 8 * loc);
			case TF64: loadM(Opt.MField, F64, 8, o, 8 * loc);
			case TI64: loadM(Opt.MField, I64, 8, o, 8 * loc);
			case TVoid: iconst(0);
			case _: loadM(Opt.MField, I32, 4, o, 4 * loc);
		};

	// a store into a heap object; references go through the write barrier
	function storeSlot(o:Int, loc:Int, t:Ty, v:Int, isNull:Bool) {
		switch t {
			case TRef(_):
				if (isNull) storeM(Opt.MField, 8, o, 8 * loc, v) else setPtr(o, op2(Add, I64, o, lconst32(8 * loc)), v, Opt.MField);
			case TF64 | TI64: storeM(Opt.MField, 8, o, 8 * loc, v);
			case TVoid:
			case _: storeM(Opt.MField, 4, o, 4 * loc, v);
		}
	}

	// rt_set_ptr(obj, slot, val)
	function setPtr(obj:Int, slot:Int, val:Int, cls = 0) {
		var prev = loadM(cls, I64, 8, slot, 0);
		storeM(cls, 8, slot, 0, val);
		var ys = loadM(Opt.MCallOnly, I64, 8, symAddr("rt_young_start"), 0);
		var ye = loadM(Opt.MCallOnly, I64, 8, symAddr("rt_young_end"), 0);
		var size = op2(Sub, I64, ye, ys);
		var done = newBlock();
		var b2 = newBlock();
		b2.cold = true;
		// the object is not young: the rest in the runtime (rthxmc.c)
		br(cmp(CULt, op2(Sub, I64, obj, ys), size), done, b2);
		seal(b2);
		cur = b2;
		call("hxmc_barrier_slow", [obj, slot, val, prev], Void);
		jmp(done);
		seal(done);
		cur = done;
	}

	// Fixed arrays often outlive the values written into them. Avoid the
	// barrier call altogether when the new value is null or outside the nursery.
	function nativeSetPtr(obj:Int, slot:Int, val:Int) {
		var prev = loadM(Opt.MElem, I64, 8, slot, 0);
		storeM(Opt.MElem, 8, slot, 0, val);
		var ys = loadM(Opt.MCallOnly, I64, 8, symAddr("rt_young_start"), 0);
		var ye = loadM(Opt.MCallOnly, I64, 8, symAddr("rt_young_end"), 0);
		var size = op2(Sub, I64, ye, ys);
		var check = newBlock(), slow = newBlock(), done = newBlock();
		slow.cold = true;
		br(cmp(CULt, op2(Sub, I64, val, ys), size), check, done);
		seal(check);
		cur = check;
		br(cmp(CULt, op2(Sub, I64, obj, ys), size), done, slow);
		seal(slow);
		cur = slow;
		call("hxmc_barrier_slow", [obj, slot, val, prev], Void);
		jmp(done);
		seal(done);
		cur = done;
	}

	// an element of a NativeArray seen as Dynamic (FnLower.nativeRead): of
	// reference storage directly, else through the runtime (rt/NArray's
	// hx_narray_get_slow, hx_narray_set_slow: the other kinds, wrappers). A
	// wrapper's kind changes, but never to AK_PTR, so the test may be shared
	// as that of a constant. At a cold site (Facts.markCold), the live
	// references are spilled around that call only
	function narrayDyn(name:String, xs:Array<Int>):Int {
		var a = xs[0];
		var get = name == "hxmc_narray_dget";
		var r = get ? newVar(I64) : -1;
		var fast = newBlock(), slow = newBlock(), join = newBlock();
		br(cmp(CEq, loadM(Opt.MConst, I32, 4, a, 4), iconst(Abi.AK_PTR)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		var ix = op1(SExt, I64, xs[1]);
		if (get) writeVar(r, cur, loadM(Opt.MElem, I64, 8, a, 8, false, ix, 8));
		else nativeSetPtr(a, op2(Add, I64, a, op2(Add, I64, lconst32(8), op2(Shl, I64, ix, iconst(3)))), xs[2]);
		jmp(join);
		cur = slow;
		var list = coldList;
		var sp = spillOpen(list, 0);
		var c = call(get ? "hx_narray_get_slow" : "hx_narray_set_slow", xs, get ? I64 : Void);
		spillClose(list, sp);
		if (get) writeVar(r, cur, c);
		jmp(join);
		seal(join);
		cur = join;
		return get ? readVar(r, cur) : iconst(0);
	}

	function tindex(o:Int):Int
		return loadM(Opt.MConst, I32, 2, o, Abi.HDR_TINDEX);

	// ---- allocation

	static function hdrLo(nslots:Int, kind:Int):Int
		return nslots | (kind << 28);

	// an object of n slots: inline bump allocation; the slow path collects.
	// zero: the slots must read as zeros (Mem.alloc), else every slot is
	// written before it is read (Mem.allocRaw). The runtime zeroes the nursery
	// in bulk, so neither stores zeros; they compare different limits, which
	// differ with RT_VERIFY=1 (Gc.hx: zeroing allocations then take the slow
	// path). At a cold site the live references are stored on the shadow
	// stack around the slow call only
	function alloc(n:Int, tidx:Int, kind:Int, zero:Bool):Int {
		f.allocs++;
		var bytes = 8 * (n + 1);
		var ptr = tlsLoad("rt_young_ptr");
		var lim = tlsLoad(zero ? "rt_young_limit" : "rt_young_rlimit");
		var res = newVar(I64);
		var fast = newBlock(), slow = newBlock(), join = newBlock();
		slow.cold = true;
		br(cmp(CGe, op2(Sub, I64, lim, ptr), lconst32(bytes)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		tlsStore("rt_young_ptr", op2(Add, I64, ptr, lconst32(bytes)));
		storeM(Opt.MInit, 4, ptr, 0, iconst(hdrLo(n, kind)));
		storeM(Opt.MInit, 4, ptr, 4, tyConst(tidx));
		var o = op2(Add, I64, ptr, lconst32(8));
		writeVar(res, cur, o);
		jmp(join);
		cur = slow;
		var list = coldList;
		var sp = spillOpen(list, 0);
		// (the header is assembled in the runtime, rthxmc.c; a stub per
		// header and size passes it, DataGen.allocStubs: one call here)
		var ts = p.tySym(tidx);
		var r = call(ALLOC_STUB + hdrLo(n, kind) + "$" + (ts != null ? ts : "#" + tidx) + "$" + bytes, [], I64);
		spillClose(list, sp);
		writeVar(res, cur, r);
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	var spillBase = -1; // the frame's spill slots (none: pushed on the slow path)

	static function hasArrayStore(ss:Array<Stmt>):Bool {
		var r = false;
		function st(s:Stmt) {
			switch s {
				case SArrSet(_) | SArrPush(_): r = true;
				case _:
			}
			if (!r) hxmc.ir.Facts.iterStmt(st, e -> {}, s);
		}
		for (s in ss)
			st(s);
		return r;
	}

	// the allocation slow path's stubs: hxmc_new$<header low word>$<type symbol or #index>$<bytes>
	public static inline var ALLOC_STUB = "hxmc_new$";

	// stores the cold site's references in a pushed area (null: none)
	function spillOpen(list:Null<Array<Local>>, extra:Int):Int {
		if (list == null || list.length + extra == 0) return -1;
		if (spillBase >= 0) {
			var at = op2(Add, I64, fr, lconst32(8 * spillBase));
			for (k in 0...list.length)
				storeM(Opt.MFrame, 8, at, 8 * k, readLocal(list[k]));
			return at;
		}
		var sp = tlsLoad("rt_sp");
		var top = op2(Add, I64, sp, lconst32(8 * (list.length + extra)));
		tlsStore("rt_sp", top);
		raiseHw(top);
		for (k in 0...list.length)
			store(8, sp, 8 * k, readLocal(list[k]));
		return sp;
	}

	function spillClose(list:Null<Array<Local>>, sp:Int) {
		if (sp < 0) return;
		for (k in 0...list.length)
			writeLocal(list[k], spillBase >= 0 ? loadM(Opt.MFrame, I64, 8, sp, 8 * k) : load(I64, 8, sp, 8 * k));
		if (spillBase < 0) tlsStore("rt_sp", sp);
	}

	// ---- cold statements

	function coldStmt(s:Stmt) {
		switch s {
			case SSet(l, e):
				writeLocal(l, ex(e));
			case SArrSet(elem, a, i, v):
				arrSet(elem, a, i, v, true);
			case SArrPush(elem, a, v):
				arrPush(elem, a, v, true);
			case SExpr(e):
				ex(e);
			case _:
				throw new Unsupported("cold statement");
		}
	}

	// ---- arrays

	static function arrKind(t:Ty):Int
		return switch t {
			case TI32: Abi.AK_I32;
			case TBool: Abi.AK_BOOL;
			case TF64: Abi.AK_F64;
			case TI64: Abi.AK_I64;
			case _: Abi.AK_PTR;
		};

	static function elemSize(t:Ty):Int
		return switch t {
			case TI32 | TBool: 4;
			case _: 8;
		};

	function bits64(t:Ty, v:Int):Int
		return switch t {
			case TF64: op1(FToBits, I64, v);
			case TI32 | TBool: op1(ZExt, I64, v);
			case _: v;
		};

	// the address of the slot holding array local `a` (rooted, or in the cold site's spill area)
	function arrSlot(a:Local, sp:Int, list:Null<Array<Local>>):Int {
		var s = refSlot.get(a);
		if (s != null) return op2(Add, I64, fr, lconst32(8 * s));
		if (noShadow && (sp < 0 || list == null || list.indexOf(a) < 0)) {
			// (measurement: a frame slot holding the array; nothing collects)
			var addr = stackAddr(f.slot(8, 8));
			store(8, addr, 0, readLocal(a));
			return addr;
		}
		if (sp < 0 || list == null || list.indexOf(a) < 0) throw new Unsupported("array local neither rooted nor spilled");
		return op2(Add, I64, sp, lconst32(8 * list.indexOf(a)));
	}

	function arrSet(elem:Ty, a:Local, i:Ex, v:Ex, cold:Bool) {
		var list = cold ? coldList : null;
		var iv = ex(i);
		var vv = ex(v);
		var av = readLocal(a);
		var k = arrKind(elem);
		var fast = newBlock(), slow = newBlock(), join = newBlock(), chk = newBlock();
		slow.cold = true;
		var kind = loadM(Opt.MHdr, I32, 4, av, 4);
		var len = loadM(Opt.MHdr, I32, 4, av, 0);
		var d = loadM(Opt.MHdr, I64, 8, av, 8);
		br(cmp(CEq, kind, iconst(k)), chk, slow);
		seal(chk);
		cur = chk;
		br(cmp(CULt, iv, len), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		var ix = op1(SExt, I64, iv);
		if (k == Abi.AK_PTR) {
			setPtr(d, op2(Add, I64, d, op2(Shl, I64, ix, iconst(3))), vv, Opt.MElem);
		} else storeM(Opt.MElem, elemSize(elem), d, 0, vv, ix, elemSize(elem));
		jmp(join);
		cur = slow;
		if (k == Abi.AK_PTR) {
			// the value is rooted in a pushed slot (after the spilled references)
			var n = list == null ? 0 : list.length;
			var sp = spillOpen(list == null ? [] : list, 1);
			store(8, sp, 8 * n, vv);
			call("hx_aset_slow", [arrSlot(a, sp, list), iv, iconst(k), op2(Add, I64, sp, lconst32(8 * n))], Void);
			spillClose(list == null ? [] : list, sp);
		} else {
			var sp = spillOpen(list, 0);
			call("hx_aset_slow", [arrSlot(a, sp, list), iv, iconst(k), bits64(elem, vv)], Void);
			spillClose(list, sp);
		}
		jmp(join);
		seal(join);
		cur = join;
	}

	function arrPush(elem:Ty, a:Local, v:Ex, cold:Bool) {
		var list = cold ? coldList : null;
		var vv = ex(v);
		var av = readLocal(a);
		var k = arrKind(elem);
		var fast = newBlock(), slow = newBlock(), join = newBlock(), c1 = newBlock(), c2 = newBlock();
		slow.cold = true;
		br(cmp(CEq, loadM(Opt.MHdr, I32, 4, av, 4), iconst(k)), c1, slow);
		seal(c1);
		cur = c1;
		var d = loadM(Opt.MHdr, I64, 8, av, 8);
		br(cmp(CNe, d, lconst(0, 0)), c2, slow);
		seal(c2);
		cur = c2;
		var len = loadM(Opt.MHdr, I32, 4, av, 0);
		var cap = op2(And, I32, loadM(Opt.MHdr, I32, 4, d, -8), iconst(0x0FFFFFFF));
		if (k == Abi.AK_I32 || k == Abi.AK_BOOL) cap = op2(Shl, I32, cap, iconst(1));
		br(cmp(CULt, len, cap), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		var ix = op1(SExt, I64, len);
		if (k == Abi.AK_PTR) setPtr(d, op2(Add, I64, d, op2(Shl, I64, ix, iconst(3))), vv, Opt.MElem) else storeM(Opt.MElem, elemSize(elem), d, 0, vv, ix, elemSize(elem));
		storeM(Opt.MHdr, 4, av, 0, op2(Add, I32, len, iconst(1)));
		jmp(join);
		cur = slow;
		if (k == Abi.AK_PTR) {
			var n = list == null ? 0 : list.length;
			var sp = spillOpen(list == null ? [] : list, 1);
			store(8, sp, 8 * n, vv);
			call("hx_apush_slow", [arrSlot(a, sp, list), iconst(k), op2(Add, I64, sp, lconst32(8 * n))], I32);
			spillClose(list == null ? [] : list, sp);
		} else {
			var sp = spillOpen(list, 0);
			call("hx_apush_slow", [arrSlot(a, sp, list), iconst(k), bits64(elem, vv)], I32);
			spillClose(list, sp);
		}
		jmp(join);
		seal(join);
		cur = join;
	}

	function arrGet(elem:Ty, a:Ex, i:Ex, checked:Bool):Int {
		var av = ex(a);
		var iv = ex(i);
		var k = arrKind(elem);
		var t = mty(elem);
		var res = newVar(t);
		var fast = newBlock(), slow = newBlock(), join = newBlock();
		slow.cold = true;
		// the header is read before the checks (every array has one): later
		// accesses the first dominates reuse it (Opt)
		var kind = loadM(Opt.MHdr, I32, 4, av, 4);
		var len = checked ? loadM(Opt.MHdr, I32, 4, av, 0) : -1;
		var d = loadM(Opt.MHdr, I64, 8, av, 8);
		if (checked) {
			var chk = newBlock();
			br(cmp(CEq, kind, iconst(k)), chk, slow);
			seal(chk);
			cur = chk;
			br(cmp(CULt, iv, len), fast, slow);
		} else br(cmp(CEq, kind, iconst(k)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		writeVar(res, cur, loadM(Opt.MElem, t, elemSize(elem), d, 0, false, op1(SExt, I64, iv), elemSize(elem)));
		jmp(join);
		cur = slow;
		var name = switch k {
			case Abi.AK_I32 | Abi.AK_BOOL: "hx_aget_i_slow";
			case Abi.AK_F64: "hx_aget_f_slow";
			case Abi.AK_I64: "hx_aget_l_slow";
			case _: "hx_aget_p_slow";
		};
		writeVar(res, cur, call(name, [av, iv], t));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	// ---- structural access

	function icache():Int {
		var k = icaches++;
		return symAddr(icSym, Abi.IC_SIZE * k);
	}

	// rt_ic: the site's cache entry for the object's type (fid: a value)
	function ic(o:Int, fid:Int):Int {
		var c = icache();
		var res = newVar(I64);
		writeVar(res, cur, c);
		var miss = newBlock(), join = newBlock();
		miss.cold = true;
		br(cmp(CNe, load(I32, 4, c, 0), tindex(o)), miss, join);
		seal(miss);
		cur = miss;
		writeVar(res, cur, call("rt_icache_miss", [o, fid, c], I64));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	function kindMatch(c:Int, t:Ty):Int {
		var kind = load(I32, 1, c, Abi.IC_KIND);
		return switch t {
			case TI32 | TBool:
				var r = newVar(I32);
				writeVar(r, cur, cmp(CEq, kind, iconst("i".code)));
				var no = newBlock(), join = newBlock();
				br(readVar(r, cur), join, no);
				seal(no);
				cur = no;
				writeVar(r, cur, cmp(CEq, kind, iconst("b".code)));
				jmp(join);
				seal(join);
				cur = join;
				readVar(r, cur);
			case TF64: cmp(CEq, kind, iconst("f".code));
			case TI64: cmp(CEq, kind, iconst("l".code));
			case _: cmp(CEq, kind, iconst("p".code));
		}
	}

	function unboxTo(t:Ty, v:Int):Int
		return switch t {
			case TI32: call("hx_unbox_int", [v], I32);
			case TBool: call("hx_unbox_bool", [v], I32);
			case TF64: call("hx_unbox_float", [v], F64);
			case TI64: call("hx_unbox_i64", [v], I64);
			case _: v;
		};

	function boxFrom(t:Ty, v:Int):Int
		return switch t {
			case TI32:
				f.allocs++;
				call("hx_box_int", [v], I64);
			case TBool: call("hx_box_bool", [v], I64);
			case TF64:
				f.allocs++;
				call("hx_box_float", [v], I64);
			case TI64:
				f.allocs++;
				call("hx_box_i64", [v], I64);
			case _: v;
		};

	// a field at a dynamic location (rt_icache.slot - 1)
	function slotLoadDyn(o:Int, loc:Int, t:Ty):Int {
		var ix = op1(SExt, I64, loc);
		return switch t {
			case TRef(_) | TI64: loadM(Opt.MField, I64, 8, o, 0, false, ix, 8);
			case TF64: loadM(Opt.MField, F64, 8, o, 0, false, ix, 8);
			case _: loadM(Opt.MField, I32, 4, o, 0, false, ix, 4);
		}
	}

	function anonGet(name:String, t:Ty, obj:Ex, hint:Null<ShapeInfo>):Int {
		var o = ex(obj);
		var fid = fidConst(name);
		var mt = mty(t);
		var res = newVar(mt);
		var join = newBlock();
		if (hint != null && hint.tindex >= 0) {
			var direct = newBlock(), other = newBlock();
			other.cold = true;
			br(cmp(CEq, tindex(o), tyConst(hint.tindex)), direct, other);
			seal(direct);
			seal(other);
			cur = direct;
			var i = hint.slot(name) - 1;
			writeVar(res, cur, slotLoad(o, hint.locs[i], t));
			jmp(join);
			cur = other;
			coldNew = true;
		}
		var c = ic(o, fid);
		var hit = newBlock(), miss = newBlock(), chk = newBlock();
		miss.cold = true;
		var slot = load(I32, 4, c, Abi.IC_SLOT);
		br(cmp(CGt, slot, iconst(0)), chk, miss);
		seal(chk);
		cur = chk;
		br(kindMatch(c, t), hit, miss);
		seal(hit);
		seal(miss);
		cur = hit;
		writeVar(res, cur, slotLoadDyn(o, op2(Sub, I32, slot, iconst(1)), t));
		jmp(join);
		cur = miss;
		writeVar(res, cur, unboxTo(t, call("hx_anon_get_slow", [o, fid], I64)));
		jmp(join);
		coldNew = false;
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	function anonSet(name:String, t:Ty, obj:Ex, v:Ex) {
		var o = ex(obj);
		var fid = fidConst(name);
		var c = ic(o, fid);
		var hit = newBlock(), miss = newBlock(), chk = newBlock(), join = newBlock();
		miss.cold = true;
		var slot = load(I32, 4, c, Abi.IC_SLOT);
		br(cmp(CGt, slot, iconst(0)), chk, miss);
		seal(chk);
		cur = chk;
		br(kindMatch(c, t), hit, miss);
		seal(hit);
		seal(miss);
		cur = hit;
		var x = ex(v);
		var loc = op1(SExt, I64, op2(Sub, I32, slot, iconst(1)));
		switch t {
			case TRef(_): setPtr(o, op2(Add, I64, o, op2(Shl, I64, loc, iconst(3))), x, Opt.MField);
			case TF64 | TI64: storeM(Opt.MField, 8, o, 0, x, loc, 8);
			case _: storeM(Opt.MField, 4, o, 0, x, loc, 4);
		}
		jmp(join);
		cur = miss;
		// C: the value is boxed, then the object expression evaluated again
		var b = boxFrom(t, ex(v));
		call("hx_anon_set_slow", [ex(obj), fidConst(name), b], Void);
		jmp(join);
		seal(join);
		cur = join;
	}

	// ---- expressions

	function ex(e:Ex):Int {
		return switch e {
			case EInt(v): iconst(v);
			case EF64(v): fconst(v);
			case EStr(s): symAddr(p.strSym(s), 8);
			case ENull(_): lconst(0, 0);
			case ELocal(l): readLocal(l);
			case EGlobal(g, _) if (p.p.globals[g].bss != null):
				symAddr(p.p.globals[g].sym);
			case EGlobal(g, t) if (tlsGlobal(g) != null):
				var v = tlsLoad(tlsGlobal(g));
				t == TF64 ? op1(BitsToF, F64, v) : t == TI64 ? v : op1(Trunc, I32, v);
			case EGlobal(g, t):
				if (Ir.isRef(t)) loadM(Opt.MGlobal, I64, 8, globalAddr(g), 0) else {
					var mt = mty(t);
					loadM(Opt.MGlobal, mt, mt == I32 ? 4 : 8, symAddr(p.scalarGlobalSym(g)), 0);
				}
			case EBin(op, x, y): bin(op, x, y);
			case ENot(x): cmp(CEq, ex(x), iconst(0));
			case EConv(c, x): conv(c, ex(x));
			case EBox(t, x): boxFrom(t, ex(x));
			case EUnbox(t, x): unboxTo(t, ex(x));
			case EField(c, idx, obj): slotLoad(ex(obj), c.locs[idx], c.fields[idx].ty);
			case EFieldAddr(c, idx, obj): op2(Add, I64, ex(obj), lconst32(8 * c.locs[idx]));
			case EAnonGet(name, t, obj, hint): anonGet(name, t, obj, hint);
			case ECast(_, x): ex(x);
			case EInstOf(c, x): instOf(ex(x), c);
			case EEnumTag(x, en):
				var base:Null<Int> = en == null || en.ctors.length == 0 ? null : en.ctors[0].tindex - en.ctors[0].tag;
				if (base != null)
					for (c in en.ctors)
						if (c.tindex - c.tag != base) base = null;
				var o = ex(x);
				if (base != null) op2(Sub, I32, tindex(o), tyConst(en.ctors[0].tindex, -en.ctors[0].tag)) else {
					var ti = op1(ZExt, I64, tindex(o));
					loadM(Opt.MConst, I32, 4, symAddr("rt_types"), Abi.TYPE_TAG, false, op2(Mul, I64, ti, lconst32(Abi.TYPE_SIZE)), 1);
				}
			case EEnumParam(c, idx, x): slotLoad(ex(x), at(idx, c.params[idx]), c.params[idx]);
			case EArrLen(a): loadM(Opt.MHdr, I32, 4, ex(a), 0);
			case EArrGet(elem, a, i): arrGet(elem, a, i, true);
			case EArrGetU(elem, a, i): arrGet(elem, a, i, false);
			case EBoxGet(t, bx): slotLoad(ex(bx), 0, t);
			case ECapture(l, idx, clos): slotLoad(ex(clos), at(idx + 1, l.captures[idx].ty), l.captures[idx].ty);
			case EType(t): symAddr(p.typeObjSym(typeIndex(t)));
			case ECall(g, args):
				var xs = [for (a in args) ex(a)];
				var c = mk(Call, mty(g.ret));
				c.sym = p.funcSym(g);
				c.keepsFrame = keepsFrame(c.sym);
				c.args = xs;
				c.argTys = [for (a in g.args) mty(a.ty) == Void ? I32 : mty(a.ty)];
				var id = add(c);
				if (inlineCands != null && inlineCands.exists(g) && g != fn) inlineSites.push({call: c, fn: g});
				id;
			case ECallDispatch(sel, sig, args):
				var xs = [for (a in args) ex(a)];
				var o = xs[0];
				var row = symAddr(p.selectorSym(sel));
				var ti = op1(ZExt, I64, tindex(o));
				var fp = load(I64, 8, row, -8 * Abi.T_FIRST, false, ti, 8);
				callInd(fp, xs, mty(sig.ret), [for (t in sig.args) mty(t)]);
			case ECallClos(s, clos, args):
				var c = ex(clos);
				var xs = [for (a in args) ex(a)];
				var fp = load(I64, 8, c, 0);
				// (a struct result: the address of the caller's memory, last)
				callInd(fp, [c].concat(xs), mty(s.ret), [I64].concat([for (t in s.args) mty(t)]).concat(s.ret.match(TStruct(_)) ? [I64] : []));
			case ECallAnon(name, s, obj, args): callAnon(name, s, obj, args);
			case ECallHost(name, args, ret): host(name, args, ret);
			case ENewObj(c): alloc(c.nslots < 1 ? 1 : c.nslots, c.tindex, Abi.K_OBJ, true);
			case ENewEnum(c, args):
				var n = c.params.length == 0 ? 1 : c.params.length;
				var o = alloc(n, c.tindex, Abi.K_OBJ, false);
				if (c.params.length == 0) storeM(Opt.MInit, 8, o, 0, lconst(0, 0));
				for (i in 0...args.length) {
					if (c.params[i].match(TI32 | TBool)) storeM(Opt.MInit, 8, o, 8 * i, lconst(0, 0));
					storeInit(o, at(i, c.params[i]), c.params[i], ex(args[i]));
				}
				o;
			case ENewArr(elem, vs): newArr(elem, vs);
			case ENewClos(l, []) if (p.staticClosures):
				// (capturing nothing: an object in the data, DataGen.closures)
				symAddr(p.closureSym(l));
			case ENewClos(l, caps):
				var o = alloc(l.captures.length + 1, l.tindex, Abi.K_OBJ, false);
				storeM(Opt.MInit, 8, o, 0, symAddr(p.funcSym(l.fn)));
				for (i in 0...caps.length)
					storeInit(o, at(i + 1, l.captures[i].ty), l.captures[i].ty, ex(caps[i]));
				o;
			case ENewBox(t, v):
				var tt = switch t {
					case TF64 | TI64: Abi.T_REFBOX_F;
					case TI32 | TBool: Abi.T_REFBOX_I;
					case _: Abi.T_REFBOX_P;
				};
				var o = alloc(1, tt, Abi.K_OBJ, false);
				storeM(Opt.MInit, 8, o, 0, lconst(0, 0));
				storeInit(o, 0, t, ex(v));
				o;
			case ENewAnon(sh, vals):
				var o = alloc(sh.nslots, sh.tindex, Abi.K_OBJ, true);
				for (i in 0...vals.length)
					storeInit(o, sh.locs[i], sh.fields[i].ty, ex(vals[i]));
				o;
		}
	}

	// a store into a new (young) object: no barrier
	function storeInit(o:Int, loc:Int, t:Ty, v:Int) {
		switch t {
			case TRef(_) | TF64 | TI64: storeM(Opt.MInit, 8, o, 8 * loc, v);
			case TVoid:
			case _: storeM(Opt.MInit, 4, o, 4 * loc, v);
		}
	}

	static function at(slot:Int, t:Ty):Int
		return t.match(TI32 | TBool) ? 2 * slot : slot;

	function typeIndex(t:TypeRef):Int
		return switch t {
			case TRClass(c): c.tindex;
			case TREnum(e): e.tindex;
			case TRBuiltin(n):
				switch n {
					case "String": 1;
					case "Int": 2;
					case "Float": 3;
					case "Bool": 4;
					case "Array": 5;
					case "hxmc_NativeArray": Abi.T_NATIVE_ARRAY;
					case "haxe_io_Bytes": 8;
					case _: 0;
				}
		};

	// hx_inst(o, lo, hi): o && KIND(o) == K_OBJ && lo <= TINDEX(o) <= hi
	function instOf(o:Int, c:ClassInfo):Int {
		var r = newVar(I32);
		writeVar(r, cur, iconst(0));
		var nn = newBlock(), join = newBlock();
		br(cmp(CNe, o, lconst(0, 0)), nn, join);
		seal(nn);
		cur = nn;
		var kind = op2(And, I32, op2(Shr, I32, load(I32, 4, o, -8), iconst(28)), iconst(15));
		var k2 = newBlock();
		br(cmp(CEq, kind, iconst(Abi.K_OBJ)), k2, join);
		seal(k2);
		cur = k2;
		var t = tindex(o);
		// lo <= t <= hi as one unsigned comparison
		writeVar(r, cur, cmp(CULe, op2(Sub, I32, t, tyConst(c.tindex)), idConst(p.spanSym(c), 0)));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	function newArr(elem:Ty, vs:Array<Ex>):Int {
		var k = arrKind(elem);
		var o:Int;
		if (vs.length == 0) {
			o = alloc(2, Abi.T_ARRAY, Abi.K_OBJ, true);
			storeM(Opt.MInit, 4, o, 4, iconst(k));
			return o;
		}
		o = call("hx_arr_new_n", [iconst(k), iconst(vs.length)], I64);
		for (i in 0...vs.length) {
			var d = loadM(Opt.MHdr, I64, 8, o, 8);
			var v = ex(vs[i]);
			switch elem {
				case TF64 | TI64: storeM(Opt.MElem, 8, d, 8 * i, v);
				case TI32 | TBool: storeM(Opt.MElem, 4, d, 4 * i, v);
				case _: setPtr(d, op2(Add, I64, d, lconst32(8 * i)), v, Opt.MElem);
			}
		}
		return o;
	}

	function bin(op:BinOp, x:Ex, y:Ex):Int {
		var a = ex(x), b = ex(y);
		return switch op {
			case Add: op2(Add, I32, a, b);
			case Sub: op2(Sub, I32, a, b);
			case Mul: op2(Mul, I32, a, b);
			case Mod: imod(a, b, I32);
			case And: op2(And, I32, a, b);
			case Or: op2(Or, I32, a, b);
			case Xor: op2(Xor, I32, a, b);
			case Shl: op2(Shl, I32, a, b);
			case Shr: op2(Sar, I32, a, b);
			case UShr: op2(Shr, I32, a, b);
			case Eq | RefEq | LEq: cmp(CEq, a, b);
			case Ne | RefNe | LNe: cmp(CNe, a, b);
			case Lt | LLt: cmp(CLt, a, b);
			case Le | LLe: cmp(CLe, a, b);
			case Gt | LGt: cmp(CGt, a, b);
			case Ge | LGe: cmp(CGe, a, b);
			case FEq: cmp(FEq, a, b);
			case FNe: cmp(FNe, a, b);
			case FLt: cmp(FLt, a, b);
			case FLe: cmp(FLe, a, b);
			case FGt: cmp(FGt, a, b);
			case FGe: cmp(FGe, a, b);
			case FAdd: op2(FAdd, F64, a, b);
			case FSub: op2(FSub, F64, a, b);
			case FMul: op2(FMul, F64, a, b);
			case FDiv: op2(FDiv, F64, a, b);
			case FMod: call("fmod", [a, b], F64);
			case LAdd: op2(Add, I64, a, b);
			case LSub: op2(Sub, I64, a, b);
			case LMul: op2(Mul, I64, a, b);
			case LDiv: ldiv(a, b);
			case LMod: imod(a, b, I64);
			case LAnd: op2(And, I64, a, b);
			case LOr: op2(Or, I64, a, b);
			case LXor: op2(Xor, I64, a, b);
			case LShl: op2(Shl, I64, a, op1(SExt, I64, b));
			case LShr: op2(Sar, I64, a, op1(SExt, I64, b));
			case LUShr: op2(Shr, I64, a, op1(SExt, I64, b));
		}
	}

	function constOf(v:Int):Null<Int> {
		var i = f.vals[v];
		return i.op == Const && i.ty == I32 ? i.imm : null;
	}

	// IMOD (Int): b == 0 or b == -1 give 0; hx_lmod (Int64): b == -1 gives 0
	function imod(a:Int, b:Int, t:MTy):Int {
		var c = t == I32 ? constOf(b) : null;
		if (c != null && c != 0 && c != -1) return op2(Rem, t, a, b);
		var r = newVar(t);
		writeVar(r, cur, t == I32 ? iconst(0) : lconst(0, 0));
		var b1 = newBlock(), b2 = newBlock(), join = newBlock();
		var zero = t == I32 ? iconst(0) : lconst(0, 0);
		var m1 = t == I32 ? iconst(-1) : lconst(-1, -1);
		if (t == I32) {
			br(cmp(CNe, b, zero), b1, join);
			seal(b1);
			cur = b1;
		} else {
			jmp(b1);
			seal(b1);
			cur = b1;
		}
		br(cmp(CNe, b, m1), b2, join);
		seal(b2);
		cur = b2;
		writeVar(r, cur, op2(Rem, t, a, b));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	// hx_ldiv: b == -1 gives -a (no overflow trap)
	function ldiv(a:Int, b:Int):Int {
		var r = newVar(I64);
		var neg = newBlock(), div = newBlock(), join = newBlock();
		br(cmp(CEq, b, lconst(-1, -1)), neg, div);
		seal(neg);
		seal(div);
		cur = neg;
		writeVar(r, cur, op1(Neg, I64, a));
		jmp(join);
		cur = div;
		writeVar(r, cur, op2(Div, I64, a, b));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	function conv(c:ConvOp, x:Int):Int {
		return switch c {
			case I2F: op1(I2F, F64, x);
			case F2I: f2i(x);
			case FNeg: op1(FNeg, F64, x);
			case I2L: op1(SExt, I64, x);
			case L2I: op1(Trunc, I32, x);
			case L2F: op1(I2F, F64, x);
			case F2L: f2l(x);
			case LNeg: op1(Neg, I64, x);
		}
	}

	// floor(x) or ceil(x), as musl computes them (exact, -0.0 kept, a NaN
	// returned as it is): WebAssembly's instructions (LinkWasm), arm64's
	// frintm and frintp; on x86-64 (no SSE4.1 assumed) inline: x itself
	// from 2^52 up and for NaN, else x truncated, one more or less when on
	// the wrong side of x, with the sign of x (the result is 0 only when x
	// is in (-1, 1), and then has x's sign)
	function floor(x:Int, ceil:Bool):Int {
		if (abi.wasm) return call(ceil ? "ceil" : "floor", [x], F64);
		if (abi.arm) return special(ceil ? "ceil" : "floor", [x], F64);
		var r = newVar(F64);
		writeVar(r, cur, x);
		var fast = newBlock(), fix = newBlock(), sign = newBlock(), join = newBlock();
		br(cmp(FLt, op1(FAbs, F64, x), fconst(4503599627370496.0)), fast, join);
		seal(fast);
		cur = fast;
		var t = newVar(F64);
		var t0 = op1(I2F, F64, op1(F2I, I64, x));
		writeVar(t, cur, t0);
		br(cmp(ceil ? FLt : FGt, t0, x), fix, sign);
		seal(fix);
		cur = fix;
		writeVar(t, cur, op2(ceil ? FAdd : FSub, F64, t0, fconst(1)));
		jmp(sign);
		seal(sign);
		cur = sign;
		var bits = op2(Or, I64, op1(FToBits, I64, readVar(t, cur)), op2(And, I64, op1(FToBits, I64, x), lconst(0, 0x80000000)));
		writeVar(r, cur, op1(BitsToF, F64, bits));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	// hx_f2i: truncation in range, else hx_f2i_slow (NaN 0, wrapping)
	function f2i(x:Int):Int {
		var r = newVar(I32);
		var c2 = newBlock(), fast = newBlock(), slow = newBlock(), join = newBlock();
		slow.cold = true;
		br(cmp(FGt, x, fconst(-2147483649.0)), c2, slow);
		seal(c2);
		cur = c2;
		br(cmp(FLt, x, fconst(2147483648.0)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		writeVar(r, cur, op1(F2I, I32, x));
		jmp(join);
		cur = slow;
		writeVar(r, cur, call("hx_f2i_slow", [x], I32));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	// hx_f2l: NaN 0, saturating
	function f2l(x:Int):Int {
		var r = newVar(I64);
		writeVar(r, cur, lconst(0, 0));
		var notNan = newBlock(), notBig = newBlock(), big = newBlock(), small = newBlock(), mid = newBlock(), join = newBlock();
		br(cmp(FEq, x, x), notNan, join);
		seal(notNan);
		cur = notNan;
		br(cmp(FGe, x, fconst(9223372036854775808.0)), big, notBig);
		seal(big);
		seal(notBig);
		cur = big;
		writeVar(r, cur, lconst(-1, 0x7fffffff));
		jmp(join);
		cur = notBig;
		br(cmp(FLt, x, fconst(-9223372036854775808.0)), small, mid);
		seal(small);
		seal(mid);
		cur = small;
		writeVar(r, cur, lconst(0, 0x80000000));
		jmp(join);
		cur = mid;
		writeVar(r, cur, op1(F2I, I64, x));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	function host(name:String, args:Array<Ex>, ret:Ty):Int {
		if (StringTools.startsWith(name, "hxmc_narray_")) {
			var xs = [for (a in args) ex(a)];
			if (name == "hxmc_narray_new") {
				var k = intLiteral(args[0], "NativeArray kind");
				var n = xs[1];
				var res = newVar(I64);
				// (1 to the most elements a header can count, by one unsigned
				// test; none: the empty array of the kind, EMPTY_ARRAY)
				var valid = newBlock(), other = newBlock(), empty = newBlock(), invalid = newBlock(), join = newBlock();
				other.cold = true;
				br(cmp(CULt, op2(Sub, I32, n, iconst(1)), iconst(k == Abi.AK_BOOL ? 0x7FFFFFE8 : k == Abi.AK_I32 ? 0x1FFFFFFA : 0x0FFFFFFD)), valid, other);
				seal(other);
				cur = other;
				br(cmp(CEq, n, iconst(0)), empty, invalid);
				seal(invalid);
				cur = invalid;
				var invalidSp = spillOpen(coldList, 0);
				call("hx_narray_bad_length", [], Void);
				spillClose(coldList, invalidSp);
				jmp(empty);
				seal(empty);
				cur = empty;
				writeVar(res, cur, symAddr(EMPTY_ARRAY + k, 8));
				jmp(join);
				seal(valid);
				cur = valid;
				// One metadata word plus the elements; the header counts 8-byte slots.
				var words = k == Abi.AK_BOOL ? op2(Shr, I32, op2(Add, I32, n, iconst(7)), iconst(3))
					: k == Abi.AK_I32 ? op2(Shr, I32, op2(Add, I32, n, iconst(1)), iconst(1)) : n;
				var a = allocDyn(op2(Add, I32, words, iconst(1)), iconst(Abi.T_NATIVE_ARRAY), iconst(k == Abi.AK_PTR ? Abi.K_PARR : Abi.K_RAW), true);
				storeM(Opt.MInit, 4, a, 0, n);
				storeM(Opt.MInit, 4, a, 4, iconst(k));
				writeVar(res, cur, a);
				jmp(join);
				seal(join);
				cur = join;
				return readVar(res, cur);
			}
			if (name == "hxmc_narray_length") return loadM(Opt.MConst, I32, 4, xs[0], 0);
			if (name == "hxmc_narray_dget" || name == "hxmc_narray_dset") return narrayDyn(name, xs);
			var suffix = name.substr(name.length - 1);
			var size = suffix == "b" ? 1 : suffix == "i" ? 4 : 8;
			var ix = op1(SExt, I64, xs[1]);
			if (StringTools.startsWith(name, "hxmc_narray_get_")) return loadM(Opt.MElem, mty(ret), size, xs[0], 8, false, ix, size);
			if (suffix == "p") nativeSetPtr(xs[0], op2(Add, I64, xs[0], op2(Add, I64, lconst32(8), op2(Shl, I64, ix, iconst(3)))), xs[2]);
			else storeM(Opt.MElem, size, xs[0], 8, xs[2], ix, size);
			return iconst(0);
		}
		// Dynamic access by a literal name: the field id is known here
		switch name {
			case "hx_dyn_get" | "hx_dyn_set" | "hx_dyn_call_field" if (args[1].match(EStr(_))):
				var n = switch args[1] {
					case EStr(n): n;
					case _: null;
				};
				var xs = [for (i in 0...args.length) i == 1 ? fidConst(n) : ex(args[i])];
				return call(name + "_fid", xs, mty(ret));
			case _:
		}
		if (hxmc.ir.FnLower.isIntrinsic(name)) return intrinsic(name, args);
		var xs = [for (a in args) ex(a)];
		return switch name {
			case "String_length": loadM(Opt.MConst, I32, 4, xs[0], 0);
			case "String_charCodeAt_i":
				var r = newVar(I32);
				writeVar(r, cur, iconst(0));
				var ok = newBlock(), join = newBlock();
				br(cmp(CULt, xs[1], load(I32, 4, xs[0], 0)), ok, join);
				seal(ok);
				cur = ok;
				writeVar(r, cur, load(I32, 2, xs[0], 8, false, op1(SExt, I64, xs[1]), 2));
				jmp(join);
				seal(join);
				cur = join;
				readVar(r, cur);
			case "hx_str_eq": strEq(xs[0], xs[1]);
			case "Math_NaN": fconst(Math.NaN);
			case "Math_POSITIVE_INFINITY": fconst(Math.POSITIVE_INFINITY);
			case "Math_NEGATIVE_INFINITY": fconst(Math.NEGATIVE_INFINITY);
			case "Math_PI": fconst(3.141592653589793);
			case "Math_abs": op1(FAbs, F64, xs[0]);
			case "Math_sqrt": op1(FSqrt, F64, xs[0]);
			// (the others, sin to pow: hxmc.rt.LibM, bound by Lower.bindHosts)
			case "Math_floor": f2i(floor(xs[0], false));
			case "Math_ceil": f2i(floor(xs[0], true));
			case "Math_round": f2i(floor(op2(FAdd, F64, xs[0], fconst(0.5)), false));
			case "Math_ffloor": floor(xs[0], false);
			case "Math_fceil": floor(xs[0], true);
			case "Math_fround": floor(op2(FAdd, F64, xs[0], fconst(0.5)), false);
			case "Math_max" | "Math_min":
				var r = newVar(F64);
				writeVar(r, cur, fconst(Math.NaN));
				var c1 = newBlock(), c2 = newBlock(), join = newBlock();
				br(cmp(FEq, xs[0], xs[0]), c1, join);
				seal(c1);
				cur = c1;
				br(cmp(FEq, xs[1], xs[1]), c2, join);
				seal(c2);
				cur = c2;
				var pick = newBlock(), other = newBlock();
				br(cmp(name == "Math_max" ? FGt : FLt, xs[0], xs[1]), pick, other);
				seal(pick);
				seal(other);
				cur = pick;
				writeVar(r, cur, xs[0]);
				jmp(join);
				cur = other;
				writeVar(r, cur, xs[1]);
				jmp(join);
				seal(join);
				cur = join;
				readVar(r, cur);
			case "Math_isNaN": cmp(FNe, xs[0], xs[0]);
			case "Math_isFinite": cmp(FEq, op2(FSub, F64, xs[0], xs[0]), fconst(0));
			case "StringBuf_addChar": stringBufAddChar(xs[0], xs[1]);
			case _:
				var sig = hxmc.ir.CInterop.SIGS.get(name);
				if (sig != null) return cCall(name, sig, xs, ret);
				var r = call(name, xs, mty(ret));
				var va = hxmc.ir.FnLower.C_VARIADIC.get(name);
				if (va != null) f.vals[r].variadic = va;
				r;
		}
	}

	// a call of a C function declared by an extern (hxmc.ir.CInterop): float
	// arguments rounded to single precision travel in the low half of a
	// float register; narrow results are extended (the callee leaves the
	// upper bits undefined); a call not declared @:hxmc.fast runs in a safe
	// region (one GC point: the references live across it are in their
	// shadow-stack slots before rt_blocking_enter). WebAssembly has one
	// thread: no safe region.
	function cCall(name:String, sig:hxmc.ir.CInterop.CSig, xs:Array<Int>, ret:Ty):Int {
		var va = hxmc.ir.FnLower.C_VARIADIC.get(name);
		// (@:hxmc.indirect: the function's address comes first)
		var indirect = StringTools.startsWith(name, hxmc.ir.CInterop.INDIRECT);
		var first = indirect ? 1 : 0;
		var args = [], sizes = [], groups = [], structs = false;
		for (k in first...xs.length) {
			var v = xs[k];
			var ct = sig.args[k];
			var k = k - first;
			switch ct {
				case CStruct(c):
					cStructArg(c, v, args, sizes, groups);
					structs = true;
					continue;
				case _:
			}
			// (variadic arguments: C's promotions make a float a double)
			if (ct == CF32 && (va == null || k < va)) {
				if (!abi.wasm) v = special("f32bits_to_freg", [special("f64_to_f32", [v], I32)], F64);
				sizes.push(4);
			} else
				sizes.push(va != null && k >= va ? 8 : hxmc.ir.CInterop.sizeOf(ct));
			args.push(v);
			groups.push(1);
		}
		// (a struct result: its address the last argument, not passed but where
		// the registers are stored, or passed in x8 on arm64; a first argument
		// on x86-64 and WebAssembly)
		var sret = switch sig.ret {
			case CStruct(c): cStructRet(c);
			case _: null;
		}
		var rt = mty(ret);
		if (sret != null)
			switch sret.ret {
				case RRegs(_):
					args.push(sret.addr);
					sizes.push(8);
					groups.push(1);
					rt = Void;
				case RSret if (abi.arm):
					args.push(sret.addr);
					sizes.push(8);
					groups.push(1);
					rt = Void;
				case RSret:
					args.unshift(sret.addr);
					sizes.unshift(8);
					groups.unshift(1);
					rt = Void;
				case RScalar(_, ct):
					rt = ct == CF64 || ct == CF32 ? F64 : ct == CI64 || ct == CPtr ? I64 : I32;
			}
		var blocking = hxmc.ir.CInterop.BLOCKING.exists(name) && !abi.wasm;
		if (blocking) call("rt_blocking_enter", [], Void);
		var r = indirect ? callInd(xs[0], args, rt) : call(name, args, rt);
		var ci = f.vals[r];
		ci.cSizes = sizes;
		if (structs) ci.cGroups = groups;
		if (va != null) ci.variadic = va;
		if (sret != null)
			switch sret.ret {
				case RRegs(ps): ci.cRet = ps;
				case RSret if (abi.arm): ci.cRet = [];
				case _:
			}
		if (blocking) call("rt_blocking_leave", [], Void);
		if (sret != null) {
			switch sret.ret {
				case RScalar(off, ct):
					switch ct {
						case CF32: store(4, sret.addr, off, special("f64_to_f32", [r], I32));
						case _: store(hxmc.ir.CInterop.sizeOf(ct), sret.addr, off, r);
					}
				case _:
			}
			return sret.addr;
		}
		return switch sig.ret {
			case CI8: op2(Sar, I32, op2(Shl, I32, r, iconst(24)), iconst(24));
			case CI16: op2(Sar, I32, op2(Shl, I32, r, iconst(16)), iconst(16));
			case CU8 | CBool: op2(And, I32, r, iconst(0xFF));
			case CU16: op2(And, I32, r, iconst(0xFFFF));
			case CF32 if (!abi.wasm): special("f32_to_f64", [special("freg_to_f32bits", [r], I32)], F64);
			case _: r;
		}
	}

	// Structs by value in C calls (CAbi: the rules of each ABI). A struct
	// value is its address: an argument is read from it, a result is stored
	// in a slot of the caller's frame, which lives until the caller returns
	// or the same call runs again.
	static function cName(name:String):String
		return StringTools.startsWith(name, hxmc.ir.CInterop.INDIRECT) ? name.substr(hxmc.ir.CInterop.INDIRECT.length) : name;

	// a part of the struct at v as an argument: a double or a float's bits in
	// a float register, or the bytes as the low bytes of a word
	function cPart(v:Int, p:CAbi.CPart):Int
		return !p.float ? cWord(v, p.off, p.size) : p.size == 8 ? load(F64, 8, v, p.off) : special("f32bits_to_freg", [load(I32, 4, v, p.off)], F64);

	// a scalar of C type ct at v + off, as the value cCall passes for it
	function cScalar(v:Int, off:Int, ct:CTy):Int
		return switch ct {
			case CF64: load(F64, 8, v, off);
			case CF32: special("f32_to_f64", [load(I32, 4, v, off)], F64);
			case CI64 | CPtr: load(I64, 8, v, off);
			case CI8 | CI16: load(I32, ct == CI8 ? 1 : 2, v, off, true);
			case _: load(I32, hxmc.ir.CInterop.sizeOf(ct), v, off);
		}

	function cStructArg(c:core.TType.TClass, v:Int, args:Array<Int>, sizes:Array<Int>, groups:Array<Int>) {
		switch CAbi.arg(abi, c) {
			case PRegs(ps) | PStack(ps):
				var stack = CAbi.arg(abi, c).match(PStack(_));
				for (k in 0...ps.length) {
					args.push(cPart(v, ps[k]));
					sizes.push(ps[k].float ? ps[k].size : 8);
					groups.push(k > 0 ? 0 : stack ? -ps.length : ps.length);
				}
			case PScalar(off, ct):
				args.push(cScalar(v, off, ct));
				sizes.push(hxmc.ir.CInterop.sizeOf(ct));
				groups.push(1);
			case PCopy:
				var l = hxmc.ir.CInterop.layout(c);
				var copy = stackAddr(f.slot((l.size + 7) & ~7, l.align > 8 ? l.align : 8));
				copyBytes(copy, v, l.size);
				args.push(copy);
				sizes.push(8);
				groups.push(1);
		}
	}

	// A function entered from C with structs by value (FuncInfo.cAbi: a
	// callback's wrapper): its parameters by the ABI's rules (CAbi), each
	// struct's parts stored in a slot whose address is the argument (or the
	// address of the caller's copy); a struct result returned in registers
	// from its memory (MFunc.cRet), or copied to the memory the caller gives
	// (cSret: a first argument, x8 on arm64). WebAssembly (hxmc's own
	// convention for callbacks, which JavaScript calls): structs by address,
	// a result stored at a first argument.
	var cSret = -1;
	var cSretSize = 0;

	function cEntry():Array<Int> {
		var sig = fn.cAbi;
		var tys:Array<MTy> = [], groups = [], sizes = [];
		var plan:Array<{at:Int, pass:Null<CAbi.CPass>}> = [];
		var rc = switch sig.ret {
			case CStruct(c): c;
			case _: null;
		};
		var rr = rc == null ? null : abi.wasm ? CAbi.CRet.RSret : CAbi.ret(abi, rc);
		var first = rr != null && rr.match(RSret) && !abi.arm;
		if (first) {
			tys.push(I64);
			groups.push(1);
			sizes.push(8);
		}
		for (ct in sig.args) {
			var at = tys.length;
			switch ct {
				case CStruct(c):
					var p = abi.wasm ? CAbi.CPass.PCopy : CAbi.arg(abi, c);
					switch p {
						case PRegs(ps) | PStack(ps):
							for (k in 0...ps.length) {
								tys.push(ps[k].float ? F64 : I64);
								sizes.push(ps[k].float ? ps[k].size : 8);
								groups.push(k > 0 ? 0 : p.match(PStack(_)) ? -ps.length : ps.length);
							}
						case PCopy | PScalar(_):
							tys.push(I64);
							sizes.push(8);
							groups.push(1);
					}
					plan.push({at: at, pass: p});
				case _:
					tys.push(ct == CF64 ? F64 : ct == CI32 ? I32 : I64);
					sizes.push(hxmc.ir.CInterop.sizeOf(ct));
					groups.push(1);
					plan.push({at: at, pass: null});
			}
		}
		f.params = tys;
		f.cParams = groups;
		f.cParamSizes = sizes;
		var ps = [];
		for (i in 0...tys.length) {
			var pi = mk(Param, tys[i]);
			pi.imm = i;
			ps.push(add(pi));
		}
		if (rc != null) {
			cSretSize = hxmc.ir.CInterop.layout(rc).size;
			switch rr {
				case RSret if (first): cSret = ps[0];
				case RSret:
					var pi = mk(Param, I64);
					pi.imm = -1;
					cSret = add(pi);
				case RRegs(parts): f.cRet = parts;
				case _:
			}
			if (abi.wasm) f.ret = Void;
		}
		var vals = [];
		for (k in 0...sig.args.length) {
			var p = plan[k];
			switch p.pass {
				case PRegs(parts) | PStack(parts):
					var c = switch sig.args[k] {
						case CStruct(c): c;
						case _: null;
					};
					var s = stackAddr(f.slot((hxmc.ir.CInterop.layout(c).size + 7) & ~7, 8));
					for (j in 0...parts.length) {
						var v = ps[p.at + j];
						if (parts[j].float && parts[j].size == 4) store(4, s, parts[j].off, special("freg_to_f32bits", [v], I32))
						else store(8, s, parts[j].off, v);
					}
					vals.push(s);
				case _: vals.push(ps[p.at]);
			}
		}
		return vals;
	}

	// n bytes from src to dst, in the largest accesses that fit
	function copyBytes(dst:Int, src:Int, n:Int) {
		var at = 0;
		while (at < n) {
			var s = n - at >= 8 ? 8 : n - at >= 4 ? 4 : n - at >= 2 ? 2 : 1;
			store(s, dst, at, load(s == 8 ? I64 : I32, s, src, at));
			at += s;
		}
	}

	// n bytes (1 to 8) at base + off as the low bytes of a word (not reading past them)
	function cWord(base:Int, off:Int, n:Int):Int {
		if (n == 8) return load(I64, 8, base, off);
		var w = -1, at = 0;
		for (s in [4, 2, 1])
			if (n - at >= s) {
				var p = op1(ZExt, I64, load(I32, s, base, off + at));
				if (at > 0) p = op2(Shl, I64, p, iconst(8 * at));
				w = w < 0 ? p : op2(Or, I64, w, p);
				at += s;
			}
		return w;
	}

	// the memory of a struct result (in this frame) and how it comes back
	function cStructRet(c:core.TType.TClass):{addr:Int, ret:CAbi.CRet} {
		var l = hxmc.ir.CInterop.layout(c);
		// (the registers' words are stored whole: the slot is rounded up to them)
		var addr = stackAddr(f.slot((l.size + 7) & ~7, l.align > 8 ? l.align : 8));
		return {addr: addr, ret: CAbi.ret(abi, c)};
	}

	// MIns.cRet of a result in registers: per part, 8 an integer register's
	// word, -8 a float register's 8 bytes, -4 its low 4 (a float)
	static function cRetParts(ps:Array<CAbi.CPart>):Array<Int>
		return [for (p in ps) !p.float ? 8 : p.size == 4 && ps.length > 0 && allFloat4(ps) ? -4 : -8];

	// (AAPCS64's aggregate of floats comes back one float per register)
	static function allFloat4(ps:Array<CAbi.CPart>):Bool {
		for (p in ps)
			if (!p.float || p.size != 4 || p.off % 8 == 0 && ps.length <= 2 && ps[ps.length - 1].off == 8) return false;
		return true;
	}

	// ---- the intrinsics of hxmc.unsafe (Mem, Atomic: the runtime's Haxe code)

	static function literal(e:Ex, what:String):String
		return switch e {
			case EStr(s): s;
			case _: throw new Unsupported(what + ": the name must be a string literal");
		}

	// a C string literal's symbol: its UTF-8 bytes in hexadecimal after
	// CSTR (DataGen.cstrLiterals defines it in .rodata, once per program)
	public static inline var CSTR = "hxmc$cstr$";

	static function cstrSym(s:String):String {
		var b = haxe.io.Bytes.ofString(s);
		return CSTR + b.toHex();
	}

	// the empty NativeArray of an element kind, its symbol: the kind after
	// EMPTY_ARRAY (DataGen.emptyArrays defines it in .data, once per program):
	// every array made with no elements is that one, which cannot change
	public static inline var EMPTY_ARRAY = "hxmc$narray_empty$";

	// the symbol of Mem.words' data: its bytes in hexadecimal after WORDS
	// (DataGen.cstrLiterals defines it in .rodata, 8-byte aligned, once per
	// program): 8-byte little-endian words, `digits` hexadecimal digits each
	// in the literal, the most significant first
	public static inline var WORDS = "hxmc$words$";

	static function wordsSym(hex:String, digits:Int):String {
		if (digits < 1 || digits > 16 || hex.length % digits != 0) throw new Unsupported("Mem.words: " + hex.length + " digits are not words of " + digits);
		var n = Std.int(hex.length / digits);
		var b = haxe.io.Bytes.alloc(8 * n);
		for (k in 0...n) {
			var v = haxe.Int64.make(0, 0);
			for (j in 0...digits) {
				var c = hex.charCodeAt(k * digits + j);
				var d = c >= "0".code && c <= "9".code ? c - "0".code : c >= "a".code && c <= "f".code ? c - "a".code + 10 : -1;
				if (d < 0) throw new Unsupported("Mem.words: not a hexadecimal digit: " + String.fromCharCode(c));
				v = (v << 4) | d;
			}
			b.setInt64(8 * k, v);
		}
		return WORDS + b.toHex();
	}

	static function intLiteral(e:Ex, what:String):Int
		return switch e {
			case EInt(v): v;
			case _: throw new Unsupported(what + ": the size must be a constant");
		}

	// Mem.target: 0 linux-x86_64, 1 linux-arm64, 2 macos-x86_64, 3 macos-arm64, 4 windows-x86_64, 5 windows-arm64, 6 wasm32-wasi,
	// 7 linux-x86_64 and 8 linux-arm64 with glibc (-D hxmc.libc=glibc: its struct layouts, hxmc.rt.Layouts),
	// 9 android-x86_64 and 10 android-arm64 (Bionic; `Mem.target() >= 9`: Android)
	public static function targetCode(abi:Abi):Int
		return abi.wasm ? 6 : abi.android ? (abi.arm ? 10 : 9) : abi.libc == "glibc" ? (abi.arm ? 8 : 7) : (abi.os == "linux" ? 0 : abi.os == "macos" ? 2 : 4) + (abi.arm ? 1 : 0);

	// the Abi constants the runtime's Haxe code may name (Mem.abi)
	static function abiConst(n:String):Int
		return switch n {
			case "TYPE_SIZE": Abi.TYPE_SIZE;
			case "TYPE_TAG": Abi.TYPE_TAG;
			case "IC_SIZE": Abi.IC_SIZE;
			case "IC_SLOT": Abi.IC_SLOT;
			case "IC_KIND": Abi.IC_KIND;
			case "IC_FN": Abi.IC_FN;
			case "IC_SIG": Abi.IC_SIG;
			case "HDR_TINDEX": Abi.HDR_TINDEX;
			case "T_FIRST": Abi.T_FIRST;
			case _: throw new Unsupported("Mem.abi: unknown constant " + n);
		}

	// an offset operand: a constant displacement, or an index (scale 1)
	function memAt(off:Ex):{disp:Int, index:Int} {
		return switch off {
			case EInt(v): {disp: v, index: -1};
			case _: {disp: 0, index: op1(SExt, I64, ex(off))};
		}
	}

	// p + off + i * scale: (base, disp, index)
	// (an index i + c or i - c: c * scale in the displacement)
	function memAtIndexed(p:Int, off:Ex, i:Ex, scale:Int):{base:Int, disp:Int, index:Int} {
		var base = p, disp = 0;
		switch off {
			case EInt(v): disp = v;
			case _: base = op2(Add, I64, p, op1(SExt, I64, ex(off)));
		}
		switch i {
			case EBin(Add, a, EInt(c)) | EBin(Add, EInt(c), a) if (c > -0x100000 && c < 0x100000):
				disp += c * scale;
				i = a;
			case EBin(Sub, a, EInt(c)) if (c > -0x100000 && c < 0x100000):
				disp -= c * scale;
				i = a;
			case _:
		}
		return {base: base, disp: disp, index: op1(SExt, I64, ex(i))};
	}

	// an inline expansion the instruction selection does (Call to hxmc$...)
	function special(name:String, args:Array<Int>, ret:MTy):Int
		return call(SPECIAL + name, args, ret);

	// instruction selection expands calls of these symbols inline
	public static inline var SPECIAL = "hxmc$";

	function intrinsic(name:String, args:Array<Ex>):Int {
		var short = name.substr(name.lastIndexOf("_") + 1);
		var atomic = StringTools.startsWith(name, "hxmc_unsafe_Atomic_");
		if (atomic) {
			var xs = [for (a in args) ex(a)];
			return switch short {
				case "load32": special("atomic_load4", [xs[0]], I32);
				case "load64": special("atomic_load8", [xs[0]], I64);
				case "store32": special("atomic_store4", [xs[0], xs[1]], Void);
				case "store64": special("atomic_store8", [xs[0], xs[1]], Void);
				case "add32": special("atomic_add4", [xs[0], xs[1]], I32);
				case "add64": special("atomic_add8", [xs[0], xs[1]], I64);
				case "exchange32": special("atomic_xchg4", [xs[0], xs[1]], I32);
				case "exchange64": special("atomic_xchg8", [xs[0], xs[1]], I64);
				case "cas32": special("atomic_cas4", [xs[0], xs[1], xs[2]], I32);
				case "cas64": special("atomic_cas8", [xs[0], xs[1], xs[2]], I64);
				case "fence": special("fence", [], Void);
				case _: throw new Unsupported("unknown intrinsic " + name);
			}
		}
		inline function ld(ty:MTy, size:Int, signed:Bool):Int {
			var p = ex(args[0]);
			var m = memAt(args[1]);
			return load(ty, size, p, m.disp, signed, m.index, 1);
		}
		inline function st(size:Int, v:Int, p:Int, m:{disp:Int, index:Int}):Int {
			store(size, p, m.disp, v, m.index, 1);
			return iconst(0);
		}
		inline function ldAt(ty:MTy, size:Int):Int {
			var m = memAtIndexed(ex(args[0]), args[1], args[2], size);
			return load(ty, size, m.base, m.disp, false, m.index, size);
		}
		inline function stAt(size:Int):Int {
			var m = memAtIndexed(ex(args[0]), args[1], args[2], size);
			store(size, m.base, m.disp, ex(args[3]), m.index, size);
			return iconst(0);
		}
		return switch short {
			case "addr" | "obj": ex(args[0]);
			case "sym": symAddr(literal(args[0], "Mem.sym"));
			case "cstr": symAddr(cstrSym(literal(args[0], "Mem.cstr")));
			case "words": symAddr(wordsSym(literal(args[0], "Mem.words"), intLiteral(args[1], "Mem.words")));
			case "tlsGet": tlsLoad(literal(args[0], "Mem.tlsGet"));
			case "tlsSet":
				tlsStore(literal(args[0], "Mem.tlsSet"), ex(args[1]));
				iconst(0);
			case "abi": iconst(abiConst(literal(args[0], "Mem.abi")));
			case "os": iconst(abi.osCode());
			case "arm": iconst(abi.arm ? 1 : 0);
			case "target": iconst(targetCode(abi));
			case "platform": iconst(abi.platformCode());
			case "stack": stackAddr(f.slot(intLiteral(args[0], "Mem.stack"), 16));
			// (a struct value's memory: FnLower.newSlot)
			case "structSlot": stackAddr(f.slot((intLiteral(args[0], "a struct slot") + 7) & ~7, intLiteral(args[1], "a struct slot")));
			case "ult": cmp(CULt, ex(args[0]), ex(args[1]));
			case "f64Bits": op1(FToBits, I64, ex(args[0]));
			case "bitsF64": op1(BitsToF, F64, ex(args[0]));
			case "getI8": ld(I32, 1, true);
			case "getU8": ld(I32, 1, false);
			case "getI16": ld(I32, 2, true);
			case "getU16": ld(I32, 2, false);
			case "getI32": ld(I32, 4, false);
			case "getI64" | "getPtr" | "getRef": ld(I64, 8, false);
			case "getF64": ld(F64, 8, false);
			case "getF32": special("f32_to_f64", [ld(I32, 4, false)], F64);
			case "setI8" | "setI16" | "setI32" | "setI64" | "setPtr" | "setRef" | "setF64":
				var p = ex(args[0]);
				var m = memAt(args[1]);
				var v = ex(args[2]);
				st(switch short {
					case "setI8": 1;
					case "setI16": 2;
					case "setI32": 4;
					case _: 8;
				}, v, p, m);
			case "setF32":
				var p = ex(args[0]);
				var m = memAt(args[1]);
				var v = special("f64_to_f32", [ex(args[2])], I32);
				st(4, v, p, m);
			case "setRefBarrier":
				var o = ex(args[0]);
				var off = switch args[1] {
					case EInt(v): lconst32(v);
					case x: op1(SExt, I64, ex(x));
				};
				var v = ex(args[2]);
				setPtr(o, op2(Add, I64, o, off), v);
				iconst(0);
			case "getU8At": ldAt(I32, 1);
			case "getU16At": ldAt(I32, 2);
			case "getI32At": ldAt(I32, 4);
			case "getI64At" | "getRefAt": ldAt(I64, 8);
			case "getF64At": ldAt(F64, 8);
			case "setU8At": stAt(1);
			case "setU16At": stAt(2);
			case "setI32At": stAt(4);
			case "setI64At" | "setF64At": stAt(8);
			// (constant sizes, type indices and kinds: the inline allocation of new objects)
			case "alloc" | "allocRaw" if (args[0].match(EInt(_)) && args[1].match(EInt(_)) && args[2].match(EInt(_))):
				var c = [for (a in args) switch a {
					case EInt(v): v;
					case _: 0;
				}];
				alloc(c[0], c[1], c[2], short == "alloc");
			case "alloc" | "allocRaw": allocDyn(ex(args[0]), ex(args[1]), ex(args[2]), short == "alloc");
			case "callRef1" | "callRef2":
				var xs = [for (a in args) ex(a)];
				callInd(xs[0], xs.slice(1), I64);
			case "call0":
				callInd(ex(args[0]), [], Void);
				iconst(0);
			// (the runtime's stubs, written by each target's emitter: DataGen.stubs)
			case "callOnStack":
				if (abi.wasm) throw new Unsupported("Mem.callOnStack: WebAssembly has no stack to switch");
				var xs = [for (a in args) ex(a)];
				call(STUB_CALL_ON_STACK, xs, Void);
				iconst(0);
			case "zero":
				if (abi.wasm) throw new Unsupported("Mem.zero: not on WebAssembly (Wasm.memset)");
				var xs = [for (a in args) ex(a)];
				call(STUB_ZERO, xs, Void);
				iconst(0);
			case "frame":
				abi.framePointers ? call(STUB_FRAME, [], I64) : lconst32(0);
			case _: throw new Unsupported("unknown intrinsic " + name);
		}
	}

	// Mem.alloc: an object of a run-time size (n slots), type index and kind;
	// zero as for alloc
	function allocDyn(n:Int, tidx:Int, kind:Int, zero:Bool):Int {
		var n64 = op1(ZExt, I64, n);
		var bytes = op2(Shl, I64, op2(Add, I64, n64, lconst(1, 0)), lconst(3, 0));
		var ptr = tlsLoad("rt_young_ptr");
		var lim = tlsLoad(zero ? "rt_young_limit" : "rt_young_rlimit");
		var res = newVar(I64);
		var fast = newBlock(), slow = newBlock(), join = newBlock();
		slow.cold = true;
		br(cmp(CGe, op2(Sub, I64, lim, ptr), bytes), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		tlsStore("rt_young_ptr", op2(Add, I64, ptr, bytes));
		var lo = op2(Or, I32, n, op2(Shl, I32, kind, iconst(28)));
		storeM(Opt.MInit, 4, ptr, 0, lo);
		storeM(Opt.MInit, 4, ptr, 4, tidx);
		writeVar(res, cur, op2(Add, I64, ptr, lconst32(8)));
		jmp(join);
		cur = slow;
		var list = coldList;
		var sp = spillOpen(list, 0);
		var r = call("hxmc_alloc_slow", [op2(Or, I32, n, op2(Shl, I32, kind, iconst(28))), tidx, op1(Trunc, I32, bytes)], I64);
		spillClose(list, sp);
		writeVar(res, cur, r);
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	function strEq(a:Int, b:Int):Int {
		var r = newVar(I32);
		writeVar(r, cur, iconst(1));
		var ne = newBlock(), c2 = newBlock(), c3 = newBlock(), slow = newBlock(), join = newBlock();
		br(cmp(CEq, a, b), join, ne);
		seal(ne);
		cur = ne;
		writeVar(r, cur, iconst(0));
		br(cmp(CEq, a, lconst(0, 0)), join, c2);
		seal(c2);
		cur = c2;
		br(cmp(CEq, b, lconst(0, 0)), join, c3);
		seal(c3);
		cur = c3;
		br(cmp(CEq, load(I32, 4, a, 0), load(I32, 4, b, 0)), slow, join);
		seal(slow);
		cur = slow;
		writeVar(r, cur, call("hx_str_eq_slow", [a, b], I32));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	// StringBuf_addChar (Str.hx): the common case inline
	function stringBufAddChar(b:Int, c:Int):Int {
		var len = load(I32, 4, b, 0);
		var d = load(I64, 8, b, 8);
		var c2 = newBlock(), fast = newBlock(), slow = newBlock(), join = newBlock();
		slow.cold = true;
		br(cmp(CULt, c, iconst(0x10000)), c2, slow);
		seal(c2);
		cur = c2;
		var cap = op2(Shl, I32, op2(And, I32, load(I32, 4, d, -8), iconst(0x0FFFFFFF)), iconst(2));
		br(cmp(CULt, len, cap), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		store(2, d, 0, c, op1(SExt, I64, len), 2);
		store(4, b, 0, op2(Add, I32, len, iconst(1)));
		jmp(join);
		cur = slow;
		call("StringBuf_addChar_slow", [b, c], Void);
		jmp(join);
		seal(join);
		cur = join;
		return iconst(0);
	}

	// a Switch on v (vals[i] to targets[i], else def); a sparse one with many
	// cases (a switch on string hashes) as a binary search down to Switches of
	// a few cases, which the instruction selectors make compare chains
	function switchTree(v:Int, vals:Array<Int>, targets:Array<MBlock>, def:MBlock) {
		var n = vals.length;
		var lo = 0, hi = 0;
		for (k in 0...n) {
			if (k == 0 || vals[k] < lo) lo = vals[k];
			if (k == 0 || vals[k] > hi) hi = vals[k];
		}
		var span:Float = (hi : Float) - lo + 1;
		if (n <= 8 || span <= 3 * n + 8) {
			switchLeaf(v, vals, targets, def);
			return;
		}
		var order = [for (k in 0...n) k];
		order.sort((a, b) -> vals[a] < vals[b] ? -1 : vals[a] > vals[b] ? 1 : 0);
		var sv = [for (k in order) vals[k]], st = [for (k in order) targets[k]];
		function tree(a:Int, b:Int) {
			if (b - a <= 4) {
				switchLeaf(v, sv.slice(a, b), st.slice(a, b), def);
				return;
			}
			var m = (a + b) >> 1;
			var l = newBlock(), r = newBlock();
			br(cmp(CLt, v, iconst(sv[m])), l, r);
			seal(l);
			seal(r);
			cur = l;
			tree(a, m);
			cur = r;
			tree(m, b);
		}
		tree(0, n);
	}

	function switchLeaf(v:Int, vals:Array<Int>, targets:Array<MBlock>, def:MBlock) {
		var sw = mk(Switch, Void);
		sw.a = v;
		sw.cases = vals;
		sw.targets = targets.concat([def]);
		add(sw);
		var from = cur;
		var done = new Map<Int, Bool>();
		for (t in sw.targets)
			if (!done.exists(t.id)) {
				done.set(t.id, true);
				edge(from, t);
			}
	}

	function callAnon(name:String, s:SigInfo, obj:Ex, args:Array<Ex>):Int {
		var o = ex(obj);
		var xs = [for (a in args) ex(a)];
		var fid = fidConst(name);
		var rt = mty(s.ret);
		var argTys = [for (t in s.args) mty(t)];
		var res = rt == Void ? -1 : newVar(rt);
		var c = ic(o, fid);
		var join = newBlock();
		var m1 = newBlock(), meth = newBlock(), notMeth = newBlock();
		// a method of the object's class with the call's signature
		var slot = load(I32, 4, c, Abi.IC_SLOT);
		br(cmp(CEq, slot, iconst(0)), m1, notMeth);
		seal(m1);
		cur = m1;
		br(cmp(CEq, load(I32, 4, c, Abi.IC_SIG), sigConst(s)), meth, notMeth);
		seal(meth);
		seal(notMeth);
		cur = meth;
		var r = callInd(load(I64, 8, c, Abi.IC_FN), [o].concat(xs), rt, [I64].concat(argTys));
		if (res >= 0) writeVar(res, cur, r);
		jmp(join);
		// a closure in a field
		cur = notMeth;
		var c1 = newBlock(), c2 = newBlock(), clos = newBlock(), slow = newBlock();
		slow.cold = true;
		br(cmp(CGt, slot, iconst(0)), c1, slow);
		seal(c1);
		cur = c1;
		br(cmp(CEq, load(I32, 1, c, Abi.IC_KIND), iconst("p".code)), c2, slow);
		seal(c2);
		cur = c2;
		var k = load(I64, 8, o, 0, false, op1(SExt, I64, op2(Sub, I32, slot, iconst(1))), 8);
		br(isSig(k, s), clos, slow);
		seal(clos);
		seal(slow);
		cur = clos;
		var r2 = callInd(load(I64, 8, k, 0), [k].concat(xs), rt, [I64].concat(argTys));
		if (res >= 0) writeVar(res, cur, r2);
		jmp(join);
		// the slow path: arguments packed in 8-byte words
		cur = slow;
		var n = xs.length == 0 ? 1 : xs.length;
		var area = f.slot(8 * n, 8);
		var av = stackAddr(area);
		if (xs.length == 0) store(8, av, 0, lconst(0, 0));
		for (i in 0...xs.length)
			store(8, av, 8 * i, switch s.args[i] {
				case TF64: op1(FToBits, I64, xs[i]);
				case TI32 | TBool: op1(ZExt, I64, xs[i]);
				case _: xs[i];
			});
		var u = call("hx_anon_call_slow", [o, fid, sigConst(s), av], I64);
		if (res >= 0) writeVar(res, cur, switch s.ret {
			case TF64: op1(BitsToF, F64, u);
			case TI32 | TBool: op1(Trunc, I32, u);
			case _: u;
		});
		jmp(join);
		seal(join);
		cur = join;
		return res >= 0 ? readVar(res, cur) : iconst(0);
	}

	// hx_is_sig(c, sig): a closure (TK_CLOSURE or TK_BOUND) of that signature
	function isSig(k:Int, s:SigInfo):Int {
		var r = newVar(I32);
		writeVar(r, cur, iconst(0));
		var nn = newBlock(), c2 = newBlock(), join = newBlock();
		br(cmp(CNe, k, lconst(0, 0)), nn, join);
		seal(nn);
		cur = nn;
		var ti = op1(ZExt, I64, tindex(k));
		var te = op2(Add, I64, symAddr("rt_types"), op2(Mul, I64, ti, lconst32(Abi.TYPE_SIZE)));
		var tk = load(I32, 1, te, 8);
		// TK_CLOSURE = 6, TK_BOUND = 7
		br(cmp(CULe, op2(Sub, I32, tk, iconst(6)), iconst(1)), c2, join);
		seal(c2);
		cur = c2;
		writeVar(r, cur, cmp(CEq, load(I32, 4, te, 12), sigConst(s)));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
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

class Unsupported {
	public var msg:String;

	public function new(msg)
		this.msg = msg;

	public function toString()
		return msg;
}
