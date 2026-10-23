package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.ir.CInterop.CTy;
import haxe.ds.Vector;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// hxmc's IR (hxmc.ir.Ir: structured statements in A-normal form) of one
// function to Mir: object-level Mir (docs/plans/codegen.md, "Object-level
// Mir": objects made, their fields, arrays, structural access, type tests,
// boxes, closures and virtual calls as operations, values typed: MIns.vty),
// (objects), which the object-level passes (Inline, Escape) work on and
// MemLower turns into memory-level Mir (lower). Here:
// - reference locals that Roots puts in shadow-stack slots live in memory
//   (fr[k]); in functions with a try block the locals a handler can see
//   live in memory, so values survive the second return of setjmp; the other
//   locals become SSA values (Braun et al., "Simple and Efficient
//   Construction of Static Single Assignment Form", on the structured input:
//   MirWriter);
// - cold sites (SCold) give their GC points (an allocation, an array store)
//   the references live across them, which the lowering roots on the slow
//   path only, and read back after it (the phis of its continuation);
// - exceptions (the handler record, setjmp), C calls and their structs by
//   value, the intrinsics of hxmc.unsafe and strings' inline helpers are
//   memory-level already.
// Constructs not handled throw Unsupported (the build fails).
class MirBuild extends MirWriter {
	var roots:Roots;
	var refSlot = new Map<Local, Int>();
	var nslots = 0;
	var fr = -1; // the frame's shadow-stack slots (value)
	var memSlot = new Map<Local, Int>(); // try functions: frame slot of a scalar local
	var varOf = new Map<Local, Int>(); // WasmGC's try functions: a local out of SSA (MFunc.vars)
	// WasmGC (wasmgc.GcGen): object-level Mir only, never lowered to memory;
	// what is memory-level here otherwise (globals, strings, the runtime's
	// intrinsics, exceptions) is the IR's own (IrNode: wasmgc.MirGen emits it as
	// the IR walker did); no Prep (p is null), fields at their index (at)
	public var gc = false;
	public static var gcSymOf:Null<FuncInfo->String>;
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

	// explicit null tests (Lower.nullChecks): the values known not to be null
	var fresh = new Map<Int, Bool>();
	// the local each value was last read from, and the locals tested since
	// their last assignment on every path here (a reference does not become
	// null when the collector moves it: a local reloaded from its slot is not
	// tested again). A nested statement list starts with what was known before
	// it and gives back nothing but the locals it assigns forgotten; a loop
	// forgets them before its body too (scoped).
	var localOfVal = new Map<Int, Int>();
	var checkedLocals = new Map<Int, Bool>();

	public var icaches = 0; // inline caches of this function (bss: <name>__ic, IC_SIZE each: MemLower)
	public var icSym:String;

	public function new(p:Prep, abi:Abi, fn:FuncInfo) {
		super(p, abi, fn);
	}

	public static function mty(t:Ty):MTy
		return switch t {
			case TI32 | TBool | TU8: I32;
			case TF64: F64;
			case TI64: I64;
			case TVoid: Void;
			case TRef(_) | TStruct(_): I64;
		};

	// the address of rt_globals[g]
	function globalAddr(g:Int):Int
		return op2(Add, I64, loadM(Opt.MConst, I64, 8, symAddr("rt_globals"), 0), idConst(p.globalOffSym(g), 0, 0, I64));

	// the symbol of a @:hxmc.threadLocal static (8 bytes per thread), or null
	// (WebAssembly: one thread, an ordinary global)
	function tlsGlobal(g:Int):Null<String>
		return abi.wasm ? null : p.p.globals[g].tls;

	// the runtime's machine-code stubs (Target.Emitter.stub)
	public static inline var STUB_CALL_ON_STACK = "hxmc_call_on_stack";
	public static inline var STUB_ZERO = "hxmc_zero";
	public static inline var STUB_FRAME = "hxmc_frame";

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

	// ---- object-level operations

	// an object-level operation (its static part: o) where control is. A
	// cold site's GC point with references across it ends its block: the
	// code after it is in a block of its own (OInfo.cont), its lowering's
	// last block, where the references get their phis (MemLower makes the
	// other operations' last blocks)
	function obj(op:Op, ty:MTy, o:OInfo, a = -1, b = -1, c = -1):MIns {
		var i = mk(op, ty);
		i.a = a;
		i.b = b;
		i.c = c;
		i.info = o;
		add(i);
		if (o.nspill > 0 && MemLower.branches(op, o)) {
			var k = newBlock();
			jmp(k);
			seal(k);
			cur = k;
			o.cont = k;
			conts.set(k.id, o);
		}
		return i;
	}

	// the continuations of operations (OInfo.cont), by block id
	var conts = new Map<Int, OInfo>();

	// a reference a cold site's slow path reads back gets a phi in its
	// continuation, which keeps the index of that reference (MIns.imm, from
	// 1: MemLower makes its arguments, one per edge; it is no trivial phi)
	override function merges(v:Int, b:MBlock):Bool {
		var o = conts.get(b.id);
		return o != null && o.relocs != null && o.relocs.exists(v);
	}

	override function phiMade(v:Int, b:MBlock, phi:MIns) {
		var o = conts.get(b.id);
		if (o != null && o.relocs != null && o.relocs.exists(v)) phi.imm = o.relocs.get(v) + 1;
	}

	inline function info():OInfo
		return new OInfo();

	// a GC point at a cold site (coldList): the references live across its
	// slow path become its arguments, read back after it (their phis in its
	// continuation: phiMade); none elsewhere (a list made only to root an
	// array store's value, OInfo.cold false, has no references)
	function gcPoint(op:Op, ty:MTy, o:OInfo, a = -1, b = -1, c = -1):MIns {
		var list = coldList;
		if (list != null) {
			o.cold = true;
			o.nspill = list.length;
			o.relocs = new Map();
			for (k in 0...list.length)
				o.relocs.set(list[k].id, k);
		}
		o.spillBase = spillBase;
		o.fr = fr >= 0;
		var args = [];
		if (list != null)
			for (l in list) {
				if (memSlot.exists(l)) throw new Unsupported("a cold site's reference in memory");
				args.push(readLocal(l));
			}
		if (fr >= 0) args.push(fr);
		var i = obj(op, ty, o, a, b, c);
		i.args = Vector.fromArrayCopy(args);
		if (list != null && hxmc.ir.Lower.nullChecks)
			for (l in list)
				checkedLocals.remove(l.id);
		return i;
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
		var vi = varOf.get(l);
		var v = if (vi != null) {
			var i = info();
			i.n = vi;
			obj(VarGet, mty(l.ty), i).id;
		} else if (s != null) loadM(Opt.MFrame, I64, 8, fr, 8 * s) else {
			var m = memSlot.get(l);
			if (m != null) {
				var t = mty(l.ty);
				var a = stackAddr(m);
				load(t, t == I32 ? 4 : 8, a, 0);
			} else readVar(l.id, cur);
		}
		if (hxmc.ir.Lower.nullChecks) localOfVal.set(v, l.id);
		return v;
	}

	function writeLocal(l:Local, v:Int) {
		if (hxmc.ir.Lower.nullChecks) checkedLocals.remove(l.id);
		var vi = varOf.get(l);
		if (vi != null) {
			var i = info();
			i.n = vi;
			obj(VarSet, Void, i, v);
			return;
		}
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

	// ---- entry

	// a function made up by hxmc (closure trampolines, main): `body` uses the
	// instruction helpers (@:access) and must end every path with a return
	public static function synthetic(p:Prep, abi:Abi, name:String, params:Vector<MTy>, ret:MTy, body:(MirBuild, Vector<Int>) -> Void):MFunc {
		var mb = new MirBuild(p, abi, null);
		var f = mb.f = new MFunc(name);
		f.params = params;
		f.ret = ret;
		var entry = mb.newBlock();
		f.entry = entry;
		mb.seal(entry);
		mb.cur = entry;
		var ps = new Vector<Int>(params.length);
		for (i in 0...params.length) {
			var pi = mb.mk(Param, params[i]);
			pi.imm = i;
			ps[i] = mb.add(pi);
		}
		body(mb, ps);
		for (b in f.blocks)
			if (!b.sealed) mb.seal(b);
		mb.tidy();
		mb.lower();
		return f;
	}

	// the function's object-level Mir lowered to memory-level Mir
	// (MemLower), its unreachable blocks dropped, its trivial phis replaced
	public function lower() {
		var ml = new MemLower(p, abi, fn, f, icSym);
		ml.run();
		icaches = ml.icaches;
		tidy();
	}

	// unreachable blocks dropped, trivial phis replaced
	function tidy() {
		prune();
		removeTrivialPhis();
	}

	var spillBase = -1; // the frame's spill slots (none: pushed on the slow path)

	// the function's object-level Mir (tidy)
	public function objects():MFunc {
		f = new MFunc(gc ? gcSymOf(fn) : p.funcSym(fn));
		f.gc = gc;
		f.blocksHere = fn.blocksHere;
		// (a parameter of type Void, a T->Void callback of a C<Void>: an i32, as a Void
		// local is; WebAssembly has no value type for Void: corpus case VoidParam)
		f.params = fn.args.mapToVector(a -> mty(a.ty) == Void ? I32 : mty(a.ty));
		f.ret = mty(fn.ret);
		var maxId = 0;
		for (l in fn.args.concat(fn.locals)) {
			if (l.id >= maxId) maxId = l.id + 1;
			varTy.set(l.id, mty(l.ty) == Void ? I32 : mty(l.ty));
			localTy.set(l.id, l.ty);
		}
		nextVar = maxId;
		// (WasmGC: the engine's collector, no shadow stack)
		roots = gc ? null : Roots.analyze(fn);
		// the frame's slots: the rooted locals' (shared by locals that never
		// live at the same time, Roots.assign), those that may be read
		// unassigned last (zeroed, unshared; in a try function, a handler may
		// read what its body had not assigned yet when it threw)
		var all = fn.args.concat(fn.locals);
		var unset = gc ? null : Roots.maybeUnset(fn);
		var a = gc ? {slotOf: new Map<Int, Int>(), nslots: 0, nzero: 0} : roots.assign(all, unset, unset);
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
		if (fn.cAbi != null && !gc) params = cEntry() else
			for (i in 0...fn.args.length) {
				var pi = mk(Param, f.params[i]);
				pi.imm = i;
				pi.vty = fn.args[i].ty;
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
		// (WasmGC: they are locals out of SSA, VarGet and VarSet, the handler
		// seeing their latest values, references too)
		if (fn.hasTry) {
			var inMem = Sys.getEnv("HXMC_TRYMEM") == "all" ? assignedInTry(fn) : memLocals(fn);
			for (l in fn.args.concat(fn.locals))
				if (gc && inMem.exists(l.id) && mty(l.ty) != Void) {
					varOf.set(l, f.vars.length);
					f.vars.push(l.ty);
				} else if (!refSlot.exists(l) && inMem.exists(l.id)) memSlot.set(l, f.slot(8, 8));
		}
		for (i in 0...fn.args.length)
			writeLocal(fn.args[i], params[i]);
		if (fn.hasTry)
			for (l in fn.locals)
				if (memSlot.exists(l) || varOf.exists(l)) {
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
		tidy();
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
					if (i.op == Phi) i.removeArg(k);
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

	// replaces phis whose operands are one value (or the phi itself), until
	// none is left (but a reference's phi in a continuation: OInfo.relocs)
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
					if (i.op != Phi) break; // (phis first)
					if (i.dead || i.imm > 0) continue;
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
				for (k in 0...i.args.length)
					i.args[k] = find(i.args[k]);
			}
		}
	}

	// ---- statements

	function stmts(ss:Vector<Stmt>) {
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
		if (gc)
			switch s {
				case SSetGlobal(g, v):
					var vals = [], phs = [];
					var t = SSetGlobal(g, irOperand(v, vals, phs));
					irOp(Void, vals, phs, null, t);
					return;
				case SAnonSet(name, t, o, v):
					var vals = [], phs = [];
					var oe = irOperand(o, vals, phs);
					var ve = irOperand(v, vals, phs);
					irOp(Void, vals, phs, null, SAnonSet(name, t, oe, ve));
					return;
				case SThrow(e):
					var vals = [], phs = [];
					var t = SThrow(irOperand(e, vals, phs));
					irOp(Void, vals, phs, null, t);
					add(mk(Unreachable, Void));
					return;
				case STry(body, catches):
					gcTry(body, catches);
					return;
				// (the branch an if on a constant does not take is not built: another
				// target's code, `if (Mem.os() == 3)`, which this one may not take)
				case SIf(EInt(c), x, y):
					scoped(c != 0 ? x : y);
					return;
				case _:
			}
		switch s {
			case SCold(id, x):
				var list = gc ? null : roots.spills.get(id);
				coldList = list == null ? [] : [for (l in list) if (!refSlot.exists(l)) l];
				coldStmt(x);
				coldList = null;
			case SSet(l, e):
				writeLocal(l, ex(e));
			case SExpr(e):
				ex(e);
			case SSetField(c, idx, obj, v):
				var o = nullCheck(ex(obj));
				var x = ex(v);
				var i = info();
				i.cls = c;
				setField(o, fieldLoc(c, idx), c.fields[idx].ty, x, isNullConst(v), i);
			case SBoxSet(t, bx, v):
				var o = ex(bx);
				var x = ex(v);
				setField(o, 0, t, x, isNullConst(v), info());
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
					// (publishes a reference, as setPtr's store)
					storeM(Opt.MGlobal, 8, globalAddr(g), 0, x, -1, 1, !isNullConst(v));
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
				scoped(x);
				jmp(join);
				if (y.length > 0) {
					seal(e);
					cur = e;
					scoped(y);
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
				forgetAssigned(body);
				scoped(body);
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
					scoped(x.body);
					jmp(join);
				}
				seal(db);
				cur = db;
				scoped(def);
				jmp(join);
				seal(join);
				cur = join;
				if (join.preds.length == 0) add(mk(Unreachable, Void));
			case SReturn(null):
				unwindTo(0);
				// (a Void body under a signature with a result, an override of
				// Base<Void>.f():T: zero, as when it falls off its end; it returned
				// nothing defined, and the inliner's phi read value -1: corpus
				// case VoidOverride, upstream's Issue13046)
				retFrom(f.ret == Void ? -1 : f.ret == F64 ? fconst(0) : f.ret == I64 ? lconst(0, 0) : iconst(0));
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
				call("rt_throw", vector(v), Void, true);
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

	function tryStmt(body:Vector<Stmt>, catches:Vector<IrCatch>) {
		var slot = f.slot(abi.handlerSize, abi.handlerAlign < 16 ? 16 : abi.handlerAlign);
		var h = stackAddr(slot);
		store(8, h, abi.handlerPrev, tlsLoad("rt_hcur"));
		store(8, h, abi.handlerSp, tlsLoad("rt_sp"));
		tlsStore("rt_hcur", h);
		var sj = mk(Call, I32);
		sj.sym = abi.setjmp;
		sj.args = abi.os == "windows" && !abi.arm ? vector(h, lconst(0, 0)) : vector(h);
		sj.argTys = new Vector(sj.args.length, I64);
		sj.returnsTwice = true;
		var r = add(sj);
		var tb = newBlock(), hb = newBlock(), join = newBlock();
		hb.handler = true;
		br(cmp(CEq, r, iconst(0)), tb, hb);
		seal(tb);
		seal(hb);
		cur = tb;
		tries.push(slot);
		scoped(body);
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
				scoped(c.body);
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
			scoped(c.body);
			jmp(join);
			cur = no;
		}
		if (!catchAll) {
			call("rt_throw", vector(readLocal(catches[0].l)), Void, true);
			add(mk(Unreachable, Void));
		}
		seal(join);
		cur = join;
		if (join.preds.length == 0) add(mk(Unreachable, Void));
	}

	static function isNullConst(e:Ex):Bool
		return e.match(ENull(_));

	// a field's slot (WasmGC: by its index, at)
	inline function fieldLoc(c:ClassInfo, idx:Int):Int
		return gc ? at(idx, c.fields[idx].ty) : c.locs[idx];

	// ---- WasmGC: the IR's own expressions and statements (IrNode)

	// e as an operand of an IrNode template: a literal stays (the IR walker
	// matches some), anything else is evaluated here, in order, and stands as
	// a placeholder local (OInfo.ph) for its value
	function irOperand(e:Ex, vals:Array<Int>, phs:Array<Local>):Ex {
		return switch e {
			case EInt(_) | EF64(_) | EStr(_) | EType(_) | ENull(_): e;
			case _:
				var v = ex(e);
				var ph = new Local(-1 - phs.length, "_" + phs.length, Ir.typeOf(e));
				vals.push(v);
				phs.push(ph);
				ELocal(ph);
		}
	}

	function irOp(ty:MTy, vals:Array<Int>, phs:Array<Local>, ?e:Ex, ?s:Stmt):Int {
		var i = info();
		i.ex = e;
		i.stmt = s;
		i.ph = Vector.fromArrayCopy(phs);
		var x = obj(IrNode, ty == Void ? Void : ty, i);
		x.args = Vector.fromArrayCopy(vals);
		if (e != null) x.vty = Ir.typeOf(e);
		return x.id;
	}

	// the expressions WasmGC keeps as the IR's (-1: the others)
	function gcEx(e:Ex):Int {
		var vals = [], phs = [];
		inline function op(t:Ex):Int
			return irOp(mty(Ir.typeOf(t)), vals, phs, t);
		return switch e {
			case EStr(_) | EType(_) | EGlobal(_, _): op(e);
			case EBin(o = Mod | FMod | LDiv | LMod, x, y):
				var xe = irOperand(x, vals, phs);
				var ye = irOperand(y, vals, phs);
				op(EBin(o, xe, ye));
			case EConv(c = F2I | F2L, x):
				var xe = irOperand(x, vals, phs);
				op(EConv(c, xe));
			case EFieldAddr(c, idx, o):
				var oe = irOperand(o, vals, phs);
				op(EFieldAddr(c, idx, oe));
			case ECallHost(name, args, ret):
				var xs = [for (a in args) irOperand(a, vals, phs)];
				irOp(mty(ret), vals, phs, ECallHost(name, Vector.fromArrayCopy(xs), ret));
			case _: -1;
		}
	}

	// a try (WasmGC): the Try terminator, the body (the dominator subtree of
	// its first block, wasmgc.MirGen), the handler entered with the exception
	// (Catch); what neither catch takes is thrown again
	function gcTry(body:Vector<Stmt>, catches:Vector<IrCatch>) {
		var tb = newBlock(), hb = newBlock(), join = newBlock();
		hb.handler = true;
		var t = mk(Try, Void);
		t.targets = vector(tb, hb);
		add(t);
		edge(cur, tb);
		edge(cur, hb);
		seal(tb);
		seal(hb);
		cur = tb;
		scoped(body);
		jmp(join);
		cur = hb;
		var exn = mk(Catch, I64);
		exn.vty = TRef(RAny);
		var e = add(exn);
		for (c in catches)
			writeLocal(c.l, e);
		var catchAll = false;
		for (c in catches) {
			if (c.test == null) {
				scoped(c.body);
				jmp(join);
				catchAll = true;
				break;
			}
			var tv = ex(c.test(ELocal(c.l)));
			var yes = newBlock(), no = newBlock();
			br(tv, yes, no);
			seal(yes);
			seal(no);
			cur = yes;
			scoped(c.body);
			jmp(join);
			cur = no;
		}
		if (!catchAll) {
			var vals = [], phs = [];
			var s = SThrow(irOperand(ELocal(catches[0].l), vals, phs));
			irOp(Void, vals, phs, null, s);
			add(mk(Unreachable, Void));
		}
		seal(join);
		cur = join;
		if (join.preds.length == 0) add(mk(Unreachable, Void));
	}

	// ---- object slots

	function getField(o:Int, loc:Int, t:Ty, i:OInfo):Int {
		if (t == TVoid) return iconst(0);
		i.t = t;
		i.loc = loc;
		return obj(GetField, mty(t), i, o).id;
	}

	// a store into a heap object (isNull: a null literal, no barrier)
	function setField(o:Int, loc:Int, t:Ty, v:Int, isNull:Bool, i:OInfo) {
		if (t == TVoid) return;
		i.t = t;
		i.loc = loc;
		i.flag = isNull;
		obj(SetField, Void, i, o, v);
	}

	// a field of a new object (into its young storage: no barrier); next:
	// the slot cleared after it (OInfo.next)
	function initField(o:Int, loc:Int, t:Ty, v:Int, next = -1) {
		var i = info();
		i.t = t;
		i.loc = loc;
		i.next = next;
		obj(InitField, Void, i, o, v);
	}

	// ---- null access (docs/hxmc.md, "Null access")

	// The reference v is about to be dereferenced. The native targets fault
	// on null (an object's fields are near its address) and the runtime's
	// fault handler throws (hxmc.rt.Faults); with explicit tests
	// (WebAssembly, where address 0 is memory and a trap cannot be caught,
	// or -D hxmc.null-checks=1), null branches to the throw (NullCheck,
	// MemLower.nullTest). A test dominated by one of the same value is dropped
	// (Opt.condProp). None in a @:hxmc.noGc function (FnLower.receiverCheck).
	inline function nullCheck(v:Int):Int
		return hxmc.ir.Lower.nullChecks && !fn.declNoGc ? nullTest(v) : v;

	function nullTest(v:Int):Int {
		if (nonNull(v)) return v;
		var lid = localOfVal.get(v);
		if (lid != null && checkedLocals.exists(lid)) return v;
		var i = info();
		i.key = tries.length == 0 ? -1 : tries[tries.length - 1];
		obj(NullCheck, Void, i, v);
		if (lid != null) checkedLocals.set(lid, true);
		return v;
	}

	// a nested statement list (null tests: checkedLocals)
	function scoped(ss:Vector<Stmt>) {
		if (!hxmc.ir.Lower.nullChecks) {
			stmts(ss);
			return;
		}
		var saved = checkedLocals;
		checkedLocals = saved.copy();
		stmts(ss);
		checkedLocals = saved;
		forgetAssigned(ss);
	}

	function forgetAssigned(ss:Vector<Stmt>) {
		if (!checkedLocals.keys().hasNext()) return;
		function st(s:Stmt) {
			switch s {
				case SSet(l, _): checkedLocals.remove(l.id);
				case _:
			}
			hxmc.ir.Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in ss)
			st(s);
	}

	// a value never null: data at a symbol (literals, type objects, static
	// closures), a frame address, an object made here, a constructor's
	// object (new), a closure's own (its call tests it: ECallClos). A
	// method's receiver may be null: a direct call does not read it (the
	// native targets fault only where the method does, and these tests
	// behave the same)
	function nonNull(v:Int):Bool {
		var i = f.vals[v];
		return switch i.op {
			case SymAddr | StackAddr: true;
			case Param: i.imm == 0 && (fn.lambda != null || isCtor(fn));
			case _: fresh.exists(v);
		}
	}

	public static function isCtor(g:FuncInfo):Bool
		return g.args.length > 0 && switch g.args[0].ty {
			case TRef(RObj(c)): c.ctor == g;
			case _: false;
		};

	// ---- allocation

	// an object of n slots (MemLower.alloc), what: OInfo.NEW_*; zero: its
	// slots must read as zeros (else every one is written first)
	function alloc(n:Int, tidx:Int, kind:Int, zero:Bool, ?i:OInfo, what = OInfo.NEW_RAW):Int {
		f.allocs++;
		if (i == null) i = info();
		i.name = what;
		i.n = n;
		i.tindex = tidx;
		i.kind = kind;
		i.zero = zero;
		var v = gcPoint(New, I64, i).id;
		if (hxmc.ir.Lower.nullChecks) fresh.set(v, true);
		return v;
	}

	// an object of a run-time size (n slots), its header's words w0 and w1
	// (MemLower.allocDyn)
	function allocDyn(n:Int, w0:Int, w1:Int, zero:Bool):Int {
		var i = info();
		i.zero = zero;
		return gcPoint(NewDyn, I64, i, n, w0, w1).id;
	}

	static function hasArrayStore(ss:Vector<Stmt>):Bool {
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

	// an array store's array: its local's shadow-stack slot, else its place
	// among the cold site's references (MemLower.arrSlot)
	function arrInfo(elem:Ty, a:Local, cold:Bool):OInfo {
		var i = info();
		i.t = elem;
		var s = refSlot.get(a);
		if (s != null) i.rootSlot = s;
		var list = cold ? coldList : null;
		if (list != null) i.listIndex = list.indexOf(a);
		return i;
	}

	function arrSet(elem:Ty, a:Local, i:Ex, v:Ex, cold:Bool) {
		var iv = ex(i);
		var vv = ex(v);
		var av = nullCheck(readLocal(a));
		var o = arrInfo(elem, a, cold);
		if (cold) gcPoint(ArraySet, Void, o, av, iv, vv) else {
			var save = coldList;
			coldList = null;
			gcPoint(ArraySet, Void, o, av, iv, vv);
			coldList = save;
		}
	}

	function arrPush(elem:Ty, a:Local, v:Ex, cold:Bool) {
		var vv = ex(v);
		var av = nullCheck(readLocal(a));
		var o = arrInfo(elem, a, cold);
		if (cold) gcPoint(ArrayPush, Void, o, av, -1, vv) else {
			var save = coldList;
			coldList = null;
			gcPoint(ArrayPush, Void, o, av, -1, vv);
			coldList = save;
		}
	}

	function arrGet(elem:Ty, a:Ex, i:Ex, checked:Bool):Int {
		var av = nullCheck(ex(a));
		var iv = ex(i);
		var o = info();
		o.t = elem;
		o.flag = checked;
		return obj(ArrayGet, mty(elem), o, av, iv).id;
	}

	// ---- structural access

	function unboxTo(t:Ty, v:Int):Int {
		if (!Ir.isScalar(t)) return v;
		var i = info();
		i.t = t;
		return obj(Unbox, mty(t), i, v).id;
	}

	function boxFrom(t:Ty, v:Int):Int {
		if (!Ir.isScalar(t)) return v;
		if (t != TBool) f.allocs++;
		var i = info();
		i.t = t;
		return obj(Box, I64, i, v).id;
	}

	function anonGet(name:String, t:Ty, obj:Ex, hint:Null<ShapeInfo>):Int {
		var o = nullCheck(ex(obj));
		var i = info();
		i.name = name;
		i.t = t;
		i.shape = hint;
		return this.obj(AnonGet, mty(t), i, o).id;
	}

	// obj.name = v through the object's type's field table: the store in
	// place when the inline cache gives a slot of the field's kind (hit),
	// else the value boxed and hx_anon_set_slow (miss; C: the object
	// expression evaluated again)
	function anonSet(name:String, t:Ty, obj:Ex, v:Ex) {
		var o = nullCheck(ex(obj));
		var fid = fidConst(name);
		var i = info();
		i.name = name;
		i.t = t;
		var test = this.obj(AnonTest, Void, i, o, fid);
		var from = cur;
		var hit = newBlock(), miss = newBlock(), join = newBlock();
		miss.cold = true;
		test.targets = vector(hit, miss);
		edge(from, hit);
		edge(from, miss);
		seal(hit);
		seal(miss);
		cur = hit;
		var x = ex(v);
		var s = info();
		s.t = t;
		this.obj(AnonStore, Void, s, o, x, test.id);
		jmp(join);
		cur = miss;
		var b = boxFrom(t, ex(v));
		call("hx_anon_set_slow", vector(ex(obj), fidConst(name), b), Void);
		jmp(join);
		seal(join);
		cur = join;
	}

	// ---- expressions

	// the values of a list of expressions, in order
	function exs(es:Vector<Ex>):Vector<Int> {
		var xs = new Vector<Int>(es.length);
		for (k in 0...es.length)
			xs[k] = ex(es[k]);
		return xs;
	}

	// an expression's value, typed (MIns.vty: its first definition's type)
	function ex(e:Ex):Int {
		var v = exValue(e);
		var i = f.vals[v];
		if (i.vty == null) i.vty = Ir.typeOf(e);
		return v;
	}

	function exValue(e:Ex):Int {
		if (gc) {
			var v = gcEx(e);
			if (v >= 0) return v;
		}
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
			case EField(c, idx, obj):
				var i = info();
				i.cls = c;
				getField(nullCheck(ex(obj)), fieldLoc(c, idx), c.fields[idx].ty, i);
			case EFieldAddr(c, idx, obj):
				var i = info();
				i.cls = c;
				i.loc = c.locs[idx];
				this.obj(FieldAddr, I64, i, nullCheck(ex(obj))).id;
			case EAnonGet(name, t, obj, hint): anonGet(name, t, obj, hint);
			// (unchecked: the value keeps its first type)
			case ECast(_, x): ex(x);
			case EInstOf(c, x):
				var i = info();
				i.cls = c;
				obj(TypeTest, I32, i, ex(x)).id;
			case EEnumTag(x, en):
				var o = nullCheck(ex(x));
				var i = info();
				i.en = en;
				obj(EnumTag, I32, i, o).id;
			case EEnumParam(c, idx, x):
				var i = info();
				i.ctor = c;
				getField(nullCheck(ex(x)), at(idx, c.params[idx]), c.params[idx], i);
			case EArrLen(a): obj(ArrayLength, I32, info(), nullCheck(ex(a))).id;
			case EArrGet(elem, a, i): arrGet(elem, a, i, true);
			case EArrGetU(elem, a, i): arrGet(elem, a, i, false);
			case EBoxGet(t, bx): getField(ex(bx), 0, t, info());
			case ECapture(l, idx, clos):
				var i = info();
				i.lambda = l;
				getField(ex(clos), at(idx + 1, l.captures[idx].ty), l.captures[idx].ty, i);
			case EType(t): symAddr(p.typeObjSym(typeIndex(t)));
			case ECall(g, args):
				var xs = exs(args);
				var c = mk(Call, mty(g.ret));
				c.sym = gc ? gcSymOf(g) : p.funcSym(g);
				c.keepsFrame = keepsFrame(c.sym);
				c.args = xs;
				c.argTys = g.args.mapToVector(a -> mty(a.ty) == Void ? I32 : mty(a.ty));
				var id = add(c);
				if (inlineCands != null && inlineCands.exists(g) && g != fn) inlineSites.push({call: c, fn: g});
				id;
			case ECallDispatch(sel, sig, args):
				var xs = exs(args);
				nullCheck(xs[0]);
				var i = info();
				i.sel = sel;
				i.sig = sig;
				var c = obj(VirtualCall, mty(sig.ret), i);
				c.args = xs;
				c.id;
			case ECallClos(s, clos, args):
				var c = ex(clos);
				var xs = new Vector<Int>(args.length + 1);
				xs[0] = c;
				for (k in 0...args.length)
					xs[k + 1] = ex(args[k]);
				nullCheck(c);
				var i = info();
				i.sig = s;
				var call = obj(ClosureCall, mty(s.ret), i);
				call.args = xs;
				call.id;
			case ECallAnon(name, s, obj, args): callAnon(name, s, obj, args);
			case ECallHost(name, args, ret): host(name, args, ret);
			case ENewObj(c):
				var i = info();
				i.cls = c;
				alloc(gc ? 2 * c.fields.length + 1 : c.nslots < 1 ? 1 : c.nslots, gc ? -1 : c.tindex, Abi.K_OBJ, true, i, OInfo.NEW_OBJECT);
			case ENewEnum(c, args):
				// (the storage is not zeroed: an Int's or Bool's word is cleared
				// before the parameter is evaluated, OInfo.next)
				inline function next(i:Int):Int
					return i < args.length && c.params[i].match(TI32 | TBool) ? i : -1;
				var n = c.params.length == 0 ? 1 : c.params.length;
				var i = info();
				i.ctor = c;
				i.next = c.params.length == 0 ? 0 : next(0);
				var o = alloc(n, c.tindex, Abi.K_OBJ, false, i, OInfo.NEW_ENUM);
				for (i in 0...args.length)
					initField(o, at(i, c.params[i]), c.params[i], ex(args[i]), next(i + 1));
				o;
			case ENewArr(elem, vs): newArr(elem, vs);
			case ENewClos(l, []) if (!gc && p.staticClosures):
				// (capturing nothing: an object in the data, DataGen.closures)
				symAddr(p.closureSym(l));
			case ENewClos(l, caps):
				var i = info();
				i.lambda = l;
				var o = alloc(l.captures.length + 1, l.tindex, Abi.K_OBJ, false, i, OInfo.NEW_CLOSURE);
				for (i in 0...caps.length)
					initField(o, at(i + 1, l.captures[i].ty), l.captures[i].ty, ex(caps[i]));
				o;
			case ENewBox(t, v):
				var tt = switch t {
					case TF64 | TI64: Abi.T_REFBOX_F;
					case TI32 | TBool: Abi.T_REFBOX_I;
					case _: Abi.T_REFBOX_P;
				};
				var i = info();
				i.t = t;
				var o = alloc(1, tt, Abi.K_OBJ, false, i, OInfo.NEW_BOX);
				initField(o, 0, t, ex(v));
				o;
			case ENewAnon(sh, vals):
				var i = info();
				i.shape = sh;
				var o = alloc(gc ? 2 * sh.fields.length + 1 : sh.nslots, gc ? -1 : sh.tindex, Abi.K_OBJ, true, i, OInfo.NEW_ANON);
				for (i in 0...vals.length)
					initField(o, gc ? at(i, sh.fields[i].ty) : sh.locs[i], sh.fields[i].ty, ex(vals[i]));
				o;
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
					case "String": Abi.T_STRING;
					case "Int": 2;
					case "Float": 3;
					case "Bool": 4;
					case "Array": 5;
					case "hxmc_NativeArray": Abi.T_NATIVE_ARRAY;
					case "Date": Abi.T_DATE;
					case "Math": Abi.T_MATH;
					case _: 0;
				}
		};

	// an Array literal: none, an empty Array (no room: the empty storage of
	// its kind); else the runtime's, each element stored (ArrayInit)
	function newArr(elem:Ty, vs:Vector<Ex>):Int {
		var i = info();
		i.t = elem;
		i.n = vs.length;
		if (vs.length == 0) return alloc(2, Abi.T_ARRAY, Abi.K_OBJ, true, i, OInfo.NEW_ARRAY);
		var o = obj(NewArray, I64, i).id;
		for (k in 0...vs.length) {
			var e = info();
			e.t = elem;
			e.n = vs.length;
			e.loc = k;
			obj(ArrayInit, Void, e, o, ex(vs[k]));
		}
		return o;
	}

	// obj.name(args) through a structural type: a method of the object's
	// class or a closure in a field (MemLower.callAnon)
	function callAnon(name:String, s:SigInfo, obj:Ex, args:Vector<Ex>):Int {
		var o = nullCheck(ex(obj));
		var xs = exs(args);
		var i = info();
		i.name = name;
		i.sig = s;
		var rt = mty(s.ret);
		var c = this.obj(AnonCall, rt, i, o);
		c.args = xs;
		return rt == Void ? iconst(0) : c.id;
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
			case FMod: call("fmod", vector(a, b), F64);
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
		if (abi.wasm) return call(ceil ? "ceil" : "floor", vector(x), F64);
		if (abi.arm) return special(ceil ? "ceil" : "floor", vector(x), F64);
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
		writeVar(r, cur, call("hx_f2i_slow", vector(x), I32));
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

	function host(name:String, args:Vector<Ex>, ret:Ty):Int {
		if (name == "hxmc_narray_lit") {
			// (FnLower: NativeArray.literal) the storage of the elements args[1...] of
			// kind args[0], as newArr makes an Array literal's: none, the empty array
			// of the kind; else one call of the runtime, then each element stored
			var k = intLiteral(args[0], "NativeArray kind");
			var n = args.length - 1;
			if (n == 0) return symAddr(EMPTY_ARRAY + k, 8);
			if (n > Abi.akMax(k)) throw "hxmc: NativeArray literal of " + n + " elements";
			var o = call("hx_narray_new_n", vector(iconst(k), iconst(n)), I64);
			for (i in 0...n) {
				var e = info();
				e.kind = k;
				e.loc = i;
				obj(NArrayInit, Void, e, o, ex(args[i + 1]));
			}
			return o;
		}
		if (StringTools.startsWith(name, "hxmc_narray_")) {
			var xs = exs(args);
			var i = info();
			if (name == "hxmc_narray_new") {
				// (1 to the most elements a header can count; none: the empty
				// array of the kind, EMPTY_ARRAY: MemLower.newNArray)
				i.kind = intLiteral(args[0], "NativeArray kind");
				return gcPoint(NewNArray, I64, i, xs[1]).id;
			}
			nullCheck(xs[0]);
			if (name == "hxmc_narray_length") return obj(NArrayLength, I32, i, xs[0]).id;
			if (name == "hxmc_narray_dget") return gcPoint(NArrayDyn, I64, i, xs[0], xs[1]).id;
			if (name == "hxmc_narray_dset") {
				gcPoint(NArrayDyn, Void, i, xs[0], xs[1], xs[2]);
				return iconst(0);
			}
			var suffix = name.substr(name.length - 1);
			i.n = suffix == "b" || suffix == "u" ? 1 : suffix == "i" ? 4 : 8;
			if (StringTools.startsWith(name, "hxmc_narray_get_")) return obj(NArrayGet, mty(ret), i, xs[0], xs[1]).id;
			i.flag = suffix == "p";
			obj(NArraySet, Void, i, xs[0], xs[1], xs[2]);
			return iconst(0);
		}
		// Dynamic access by a literal name: the field id is known here
		switch name {
			case "hx_dyn_get" | "hx_dyn_set" | "hx_dyn_call_field" if (args[1].match(EStr(_))):
				var n = switch args[1] {
					case EStr(n): n;
					case _: null;
				};
				var xs = new Vector<Int>(args.length);
				for (i in 0...args.length)
					xs[i] = i == 1 ? fidConst(n) : ex(args[i]);
				return call(name + "_fid", xs, mty(ret));
			case _:
		}
		if (hxmc.ir.FnLower.isIntrinsic(name)) return intrinsic(name, args);
		var xs = exs(args);
		return switch name {
			case "String_length": strLen(nullCheck(xs[0]));
			case "String_charCodeAt_i":
				nullCheck(xs[0]);
				var r = newVar(I32);
				writeVar(r, cur, iconst(0));
				var ok = newBlock(), join = newBlock();
				br(cmp(CULt, xs[1], strLen(xs[0])), ok, join);
				seal(ok);
				cur = ok;
				writeVar(r, cur, load(I32, 2, xs[0], 4, false, op1(SExt, I64, xs[1]), 2)); // (the units after the length)
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
			case "StringBuf_addChar": stringBufAddChar(nullCheck(xs[0]), xs[1]);
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
	function cCall(name:String, sig:hxmc.ir.CInterop.CSig, xs:Vector<Int>, ret:Ty):Int {
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
				if (!abi.wasm) v = special("f32bits_to_freg", vector(special("f64_to_f32", vector(v), I32)), F64);
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
		if (blocking) call("rt_blocking_enter", vector(), Void);
		var r = indirect ? callInd(xs[0], Vector.fromArrayCopy(args), rt) : call(name, Vector.fromArrayCopy(args), rt);
		var ci = f.vals[r];
		ci.cCall = true;
		ci.cSizes = Vector.fromArrayCopy(sizes);
		if (structs) ci.cGroups = Vector.fromArrayCopy(groups);
		if (va != null) ci.variadic = va;
		if (sret != null)
			switch sret.ret {
				case RRegs(ps):
					ci.structRet = true;
					ci.cRet = ps;
				case RSret if (abi.arm): ci.structRet = true;
				case _:
			}
		if (blocking) call("rt_blocking_leave", vector(), Void);
		if (sret != null) {
			switch sret.ret {
				case RScalar(off, ct):
					switch ct {
						case CF32: store(4, sret.addr, off, special("f64_to_f32", vector(r), I32));
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
			case CF32 if (!abi.wasm): special("f32_to_f64", vector(special("freg_to_f32bits", vector(r), I32)), F64);
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
		return !p.float ? cWord(v, p.off, p.size) : p.size == 8 ? load(F64, 8, v, p.off) : special("f32bits_to_freg", vector(load(I32, 4, v, p.off)), F64);

	// a scalar of C type ct at v + off, as the value cCall passes for it
	function cScalar(v:Int, off:Int, ct:CTy):Int
		return switch ct {
			case CF64: load(F64, 8, v, off);
			case CF32: special("f32_to_f64", vector(load(I32, 4, v, off)), F64);
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
		f.params = Vector.fromArrayCopy(tys);
		f.cParams = Vector.fromArrayCopy(groups);
		f.cParamSizes = Vector.fromArrayCopy(sizes);
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
				case RRegs(parts):
					f.structRet = true;
					f.cRet = parts;
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
						if (parts[j].float && parts[j].size == 4) store(4, s, parts[j].off, special("freg_to_f32bits", vector(v), I32))
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

	// instruction selection expands calls of these symbols inline
	public static inline var SPECIAL = "hxmc$";

	function intrinsic(name:String, args:Vector<Ex>):Int {
		var short = name.substr(name.lastIndexOf("_") + 1);
		var atomic = StringTools.startsWith(name, "hxmc_unsafe_Atomic_");
		if (atomic) {
			var xs = exs(args);
			return switch short {
				case "load32": special("atomic_load4", vector(xs[0]), I32);
				case "load64": special("atomic_load8", vector(xs[0]), I64);
				case "store32": special("atomic_store4", vector(xs[0], xs[1]), Void);
				case "store64": special("atomic_store8", vector(xs[0], xs[1]), Void);
				case "add32": special("atomic_add4", vector(xs[0], xs[1]), I32);
				case "add64": special("atomic_add8", vector(xs[0], xs[1]), I64);
				case "exchange32": special("atomic_xchg4", vector(xs[0], xs[1]), I32);
				case "exchange64": special("atomic_xchg8", vector(xs[0], xs[1]), I64);
				case "cas32": special("atomic_cas4", vector(xs[0], xs[1], xs[2]), I32);
				case "cas64": special("atomic_cas8", vector(xs[0], xs[1], xs[2]), I64);
				case "fence": special("fence", vector(), Void);
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
			case "typeIndexOf":
				switch args[0] {
					case EType(TRClass(c)) | ECast(_, EType(TRClass(c))) if (!c.isInterface): tyConst(c.tindex);
					case _: throw new Unsupported("Mem.typeIndexOf: a class, by name");
				}
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
			case "getF32": special("f32_to_f64", vector(ld(I32, 4, false)), F64);
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
				var v = special("f64_to_f32", vector(ex(args[2])), I32);
				st(4, v, p, m);
			case "setRefBarrier":
				var o = ex(args[0]);
				var off = switch args[1] {
					case EInt(v): lconst32(v);
					case x: op1(SExt, I64, ex(x));
				};
				var v = ex(args[2]);
				obj(RefStore, Void, info(), o, off, v);
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
			case "alloc" | "allocRaw":
				// (the kind, a literal: K_OBJ a record; else an array of 8-byte
				// slots, references or not)
				var n = ex(args[0]), t = ex(args[1]);
				switch args[2] {
					case EInt(0): allocDyn(n, op2(Or, I32, t, op2(Shl, I32, n, iconst(16))), iconst(0), short == "alloc"); // (K_OBJ)
					case EInt(_): allocDyn(n, arrWord(t, n), n, short == "alloc");
					case _: throw new Unsupported("Mem.alloc: the kind, not a literal");
				}
			case "allocArray" | "allocArrayRaw":
				// (the type, the length, the words)
				var t = ex(args[0]), len = ex(args[1]), words = ex(args[2]);
				allocDyn(words, arrWord(t, words), len, short == "allocArray");
			case "callRef1" | "callRef2":
				var xs = exs(args);
				callInd(xs[0], xs.slice(1), I64);
			case "call0":
				callInd(ex(args[0]), vector(), Void);
				iconst(0);
			// (the runtime's stubs, written by each target's emitter: DataGen.stubs)
			case "callOnStack":
				if (abi.wasm) throw new Unsupported("Mem.callOnStack: WebAssembly has no stack to switch");
				call(STUB_CALL_ON_STACK, exs(args), Void);
				iconst(0);
			case "zero":
				if (abi.wasm) throw new Unsupported("Mem.zero: not on WebAssembly (Wasm.memset)");
				call(STUB_ZERO, exs(args), Void);
				iconst(0);
			case "frame":
				abi.framePointers ? call(STUB_FRAME, vector(), I64) : lconst32(0);
			case _: throw new Unsupported("unknown intrinsic " + name);
		}
	}
	// a string's length (its payload's first word: hxmc.rt.Types)
	function strLen(s:Int):Int
		return loadM(Opt.MConst, I32, 4, s, 0);

	// the type of NativeArray storage of element kind k (hxmc.rt.Types.naType)
	public static function naType(k:Int):Int
		return Abi.T_NATIVE_ARRAY - k;

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
		br(cmp(CEq, strLen(a), strLen(b)), slow, join);
		seal(slow);
		cur = slow;
		writeVar(r, cur, call("hx_str_eq_slow", vector(a, b), I32));
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
		var cap = op2(Shl, I32, load(I32, 4, d, -4), iconst(2));
		br(cmp(CULt, len, cap), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		store(2, d, 0, c, op1(SExt, I64, len), 2);
		store(4, b, 0, op2(Add, I32, len, iconst(1)));
		jmp(join);
		cur = slow;
		call("StringBuf_addChar_slow", vector(b, c), Void);
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
		sw.cases = Vector.fromArrayCopy(vals);
		var ts = new Vector<MBlock>(targets.length + 1);
		for (k in 0...targets.length)
			ts[k] = targets[k];
		ts[targets.length] = def;
		sw.targets = ts;
		add(sw);
		var from = cur;
		var done = new Map<Int, Bool>();
		for (t in sw.targets)
			if (!done.exists(t.id)) {
				done.set(t.id, true);
				edge(from, t);
			}
	}

}

class Unsupported {
	public var msg:String;

	public function new(msg)
		this.msg = msg;

	public function toString()
		return msg;
}
