package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Inlining of small functions into their callers, on object-level Mir (after
// MirBuild, before Escape and MemLower): the callee's blocks are copied in
// place of the call, its parameters replaced by the arguments, its returns
// by jumps to the rest of the caller's block (a phi joins the results); the
// copy's operations are lowered in the caller (its inline caches the
// caller's).
//
// Candidates are decided on hxmc's IR (hxmc.ir) (`candidate`: no try, a small body),
// so that Fingerprint can put a candidate's body into the key of every
// module calling it; the final decision is on the callee's object-level Mir:
// few instructions on its fast path once lowered (size: what MemLower makes
// of each operation, counted on the operation; a shadow-stack frame stays the
// copy's own: it pushes and pops it).
class Inline {
	public static inline var MAX_IR = 40; // IR nodes of a candidate
	// instructions outside slow paths: of a callee inlined anywhere, at a
	// call in a loop, and of the runtime's Haxe functions (hxmc.rt) outside
	// loops: 3, those no bigger than their call (Bytes.get, set and length, then:
	// the tool 0.2% smaller, its self-compile 1% less CPU; 16 inlines
	// hx_str_or_null at every concatenation too: 0.5% faster still, the
	// port 1.2% larger) (size against speed;
	// HXMC_INLINE=<flat>,<loop>,<runtime flat>, for every target)
	public static var MAX_FLAT = limit(0, 16);
	public static var MAX_LOOP = limit(1, 48);
	public static var MAX_FLAT_RT = limit(2, 3);
	// WebAssembly (wasm32-wasi): an engine inlines again, and modules are
	// downloaded: 4 and 16 take 6% off the playground's module (828 KB raw,
	// 269 KB gzipped) with its self-compile under node and the benchmarks'
	// run times unchanged (4, 8 makes mandelbrot 60% slower)
	public static var WASM_FLAT = limit(0, 4);
	public static var WASM_LOOP = limit(1, 16);

	// the limits of a call site (in a loop, of a runtime function, else)
	public static function maxSize(wasm:Bool, inLoop:Bool, rt:Bool):Int
		return inLoop ? (wasm ? WASM_LOOP : MAX_LOOP) : rt ? MAX_FLAT_RT : wasm ? WASM_FLAT : MAX_FLAT;

	static function limit(k:Int, def:Int):Int {
		var e = Sys.getEnv("HXMC_INLINE");
		if (e == null) return def;
		var p = e.split(",");
		return k < p.length ? Std.parseInt(p[k]) : def;
	}
	public static inline var DEPTH = 2; // levels of inlining (Fingerprint keys callers to that depth)

	// whether f may be inlined (the IR test); not a function that runs the
	// collector (@:hxmc.collects): the calls in its body are to the
	// collector's own no-GC code, during which its callers' shadow-stack
	// slots would be taken to keep their values (MIns.keepsFrame); not one
	// without its body (FuncInfo.hostCode); not one whose calls or throws carry
	// their positions (Lower.sitePositions: its frame is in a stack)
	public static function candidate(f:FuncInfo):Bool {
		if (f.hasTry || f.collects || f.hostCode) return false;
		var n = 0, sited = false;
		function ex(e:Ex) {
			if (++n > MAX_IR) return;
			hxmc.ir.Facts.iterEx(ex, e);
		}
		function st(s:Stmt) {
			switch s {
				case SPos(_, _, min, _):
					if (min >= 0) sited = true;
					return; // (-debug: the same decisions)
				case _:
			}
			if (++n > MAX_IR) return;
			hxmc.ir.Facts.iterStmt(st, ex, s);
		}
		for (s in f.body) {
			st(s);
			if (n > MAX_IR) return false;
		}
		return !sited;
	}

	// the instructions of f outside slow paths once lowered, from its
	// object-level Mir: an object-level operation counts what MemLower makes
	// of it outside slow paths (opSize), the others one each but constants
	// and addresses, which fold into their users (-1: never inlined)
	public static function size(f:MFunc, gc = false):Int {
		var n = 0;
		for (b in f.blocks)
			if (!b.cold)
				for (i in b.ins) {
					if (i.op == Call && i.returnsTwice) return -1;
					if (i.op != Const && i.op != ConstF && i.op != SymAddr && i.op != StackAddr && i.op != Param)
						n += !i.isObj() ? 1 : gc ? gcOpSize(i) : opSize(i);
				}
		return n;
	}

	// what wasmgc.MirGen makes of an object-level operation (no barriers,
	// nursery or inline caches: mostly one instruction and its casts; an
	// array access its kind and range tests inline, a structural one its
	// layout tests)
	static function gcOpSize(i:MIns):Int {
		var o = i.info;
		return switch i.op {
			case InitField | ArrayInit: 0; // (operands of the struct.new)
			case TypeTest | ClosureCall: 2;
			case VirtualCall: 3;
			case AnonGet: o.shape != null ? 3 : 6;
			case AnonCall: 10;
			case ArrayGet: 4;
			case ArraySet: 5;
			case ArrayPush: 6;
			case _: 1;
		}
	}

	// what MemLower makes of an object-level operation outside its slow paths
	// (its blocks' instructions but constants, its continuation's phis)
	static function opSize(i:MIns):Int {
		var o = i.info;
		inline function ref(t:Ty):Bool
			return t.match(TRef(_));
		// a reference stored with the write barrier (MemLower.setPtr: its tests)
		var barrier = 11;
		// a cold site's references: pushed on the shadow stack (the push's
		// high-water test and the block after it are not slow paths), or in
		// the frame's own slots
		var spill = !o.cold || o.nspill == 0 ? 0 : o.fr ? -o.nspill : 2 + 2 * o.nspill;
		return spill + switch i.op {
			case NullCheck: 2;
			case New: 12 + (o.name == OInfo.NEW_ARRAY ? 2 : o.name == OInfo.NEW_OBJECT || o.name == OInfo.NEW_ANON || o.name == OInfo.NEW_RAW ? 0 : 1) + (o.next >= 0 ? 1 : 0);
			case NewDyn: 15;
			case InitField: o.next >= 0 ? 2 : 1;
			case GetField | ArrayLength | NArrayLength: 1;
			case SetField: ref(o.t) && !o.flag ? 1 + barrier : 1;
			case FieldAddr: 1;
			case EnumTag: 2;
			case TypeTest: 8;
			case Box | Unbox: o.t.match(TI32 | TBool | TF64 | TI64) ? 1 : 0;
			case VirtualCall: 4;
			case ClosureCall: 2;
			case AnonGet: o.shape != null && o.shape.tindex >= 0 ? 6 : 16;
			case AnonTest: 12;
			case AnonStore: ref(o.t) ? 4 + barrier : 3;
			case AnonCall: 40;
			case ArrayGet: o.flag ? 11 : 9;
			// (a reference stored: rooted in a pushed slot on the slow path)
			case ArraySet: o.t.match(TI32 | TBool | TF64 | TI64) ? 10 : 11 + barrier + (o.fr ? 0 : 4);
			case ArrayPush: o.t.match(TI32 | TBool | TF64 | TI64) ? 13 : 14 + barrier + (o.fr ? 0 : 4);
			case NewArray: 2;
			case ArrayInit: o.t.match(TI32 | TBool | TF64 | TI64) ? 2 : 3 + barrier;
			case NewNArray: 25;
			case NArrayInit: o.kind == Abi.AK_PTR ? 1 + barrier : 1;
			case NArrayGet: 2;
			case NArraySet: o.flag ? 3 + barrier : 2;
			case NArrayDyn: 10;
			case RefStore: 1 + barrier;
			case _: 1;
		};
	}

	// the callee's object-level Mir (mb's) when it can be inlined, judged on
	// the size of its lowering (size; built once per caller module; a callee
	// with a shadow-stack frame keeps it: its copy pushes and pops it)
	public static function template(mb:MirBuild, mf:MFunc):Null<Template> {
		var n = size(mf);
		return n >= 0 && n <= MAX_LOOP ? {mf: mf, sites: mb.inlineSites, size: n} : null;
	}

	// drops the blocks no longer reachable (after a callee that never returns)
	static function prune(f:MFunc) {
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

	public static var devirtOn = Sys.getEnv("HXMC_DEVIRT") != "0";

	// whether inlining the call may let Escape replace an object: one made in
	// the caller passed to it, or one the callee makes returned (WasmGC
	// inlines those up to the native loop limit: an engine inlines small
	// functions itself, but does not take objects out of the heap)
	public static function objectsMeet(f:MFunc, call:MIns, t:Template):Bool {
		for (a in call.args)
			if (madeHere(f, a, 0)) return true;
		for (b in t.mf.blocks) {
			var r = b.term();
			if (r != null && r.op == Ret && r.a >= 0 && madeHere(t.mf, r.a, 0)) return true;
		}
		return false;
	}

	// v is an object made in f (New, through copies and phis)
	static function madeHere(f:MFunc, v:Int, depth:Int):Bool {
		var x = f.vals[v];
		while (x.op == Copy)
			x = f.vals[x.a];
		if (x.op == New) return x.info.name != OInfo.NEW_ARRAY;
		if (x.op != Phi || depth > 2) return false;
		for (a in x.args)
			if (a != x.id && !madeHere(f, a, depth + 1)) return false;
		return true;
	}

	// Devirtualization: a virtual call on an object made in f (New: its class
	// exactly known) calls the class's implementation of the selector
	// directly (the function the dispatch row has: DataGen.dispatch), when that
	// is of f's module (the module's key covers it: Fingerprint); returned are
	// the calls made direct, to be inlined where they may be
	public static function devirtualize(f:MFunc, module:String, selectors:Array<{name:String, sig:SigInfo}>, sym:FuncInfo->String):Array<{call:MIns, fn:FuncInfo}> {
		var r = [];
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead || i.op != VirtualCall) continue;
				var x = f.vals[i.args[0]];
				while (x.op == Copy)
					x = f.vals[x.a];
				if (x.op != New || x.info.name != OInfo.NEW_OBJECT || x.info.cls == null || x.info.cls.isInterface) continue;
				var sel = i.info.sel;
				var g = x.info.cls.findMethod(selectors[sel].name);
				if (g == null || g.dispatchSel != sel || g.module != module || g.sret || g.cAbi != null || g.args.length != i.args.length) continue;
				i.op = Call;
				i.sym = sym(g);
				i.a = -1;
				i.argTys = g.args.mapToVector(a -> MirBuild.mty(a.ty) == Void ? I32 : MirBuild.mty(a.ty));
				i.info = null;
				r.push({call: i, fn: g});
			}
		return r;
	}

	// the blocks of f in loops (an edge back in reverse postorder closes a
	// loop over the blocks between: Cfg.retreatSpans): marked with the mark
	// returned
	public static function loopBlocks(f:MFunc):Int {
		var cfg = f.cfg();
		var inLoop = cfg.retreatSpans();
		var m = f.newMark();
		for (k in 0...cfg.size)
			if (inLoop[k]) cfg.rpo[k].mark = m;
		return m;
	}

	// replaces each call (in f) by a copy of its callee's template
	// (returns the calls to candidates in the copies: inlined in turn, to a depth)
	public static function run(f:MFunc, sites:Array<{call:MIns, callee:Template}>):Array<{call:MIns, fn:FuncInfo}> {
		var more = [];
		if (sites.length == 0) return more;
		f.edited();
		var nextBlock = 0;
		for (b in f.blocks)
			if (b.id >= nextBlock) nextBlock = b.id + 1;
		var replFrom:Array<Int> = [], replTo:Array<Int> = []; // call value -> result value
		for (site in sites) {
			var c = site.call, g = site.callee.mf;
			var b = c.block;
			var k = b.ins.indexOf(c);
			if (k < 0) continue;
			f.allocs += g.allocs;
			// (a copy of a function that enters a safe region: the caller's
			// calls no longer keep its frame, MIns.keepsFrame, MemLower's too)
			if (g.blocksHere) f.blocksHere = true;
			// the rest of the block after the call
			var tail = new MBlock(nextBlock++);
			tail.cold = b.cold;
			f.blocks.push(tail);
			tail.ins = b.ins.slice(k + 1);
			for (i in tail.ins)
				i.block = tail;
			b.ins = b.ins.slice(0, k);
			tail.succs = b.succs;
			for (s in tail.succs) {
				var q = s.preds.indexOf(b);
				while (q >= 0) {
					s.preds[q] = tail;
					q = s.preds.indexOf(b);
				}
			}
			b.succs = [];
			// the copy
			// (the template is shared by the threads: maps by its numbers, no marks)
			var vmap = MFunc.ints(g.vals.length, -1);
			var gmax = 0;
			for (gb in g.blocks)
				if (gb.id > gmax) gmax = gb.id;
			var bmap = new haxe.ds.Vector<MBlock>(gmax + 1);
			for (gb in g.blocks) {
				var nb = new MBlock(nextBlock++);
				nb.cold = gb.cold || b.cold;
				nb.sealed = nb.filled = true;
				bmap[gb.id] = nb;
				f.blocks.push(nb);
			}
			var slotBase = f.slots.length;
			for (s in g.slots)
				f.slots.push(s);
			// values first (operands may refer forward: phis)
			for (gb in g.blocks)
				for (i in gb.ins) {
					if (i.op == Param) {
						vmap[i.id] = c.args[i.imm];
						continue;
					}
					var x = new MIns(i.op, i.ty);
					x.id = f.vals.length;
					f.vals.push(x);
					vmap[i.id] = x.id;
				}
			var rets:Array<{block:MBlock, v:Int}> = [];
			for (gb in g.blocks) {
				var nb = bmap[gb.id];
				nb.preds = [for (p in gb.preds) bmap[p.id]];
				nb.succs = [for (s in gb.succs) bmap[s.id]];
				for (i in gb.ins) {
					if (i.op == Param) continue;
					var x = f.vals[vmap[i.id]];
					inline function m(v:Int):Int
						return v < 0 ? v : vmap[v];
					x.a = m(i.a);
					x.b = m(i.b);
					x.c = m(i.c);
					x.imm = i.imm;
					x.imm2 = i.imm2;
					x.vty = i.vty;
					if (i.info != null) {
						x.info = i.info.copy(i.info.cont == null ? null : bmap[i.info.cont.id]);
						// (a copy's null tests share a block of their own, as a
						// callee's: a try around the call keeps it inside)
						if (i.op == NullCheck && x.info.key == -1) x.info.key = -2 - c.id;
					}
					// (the call's position: the copy is the caller's code, its
					// frame the caller's, which a stack names with the call's
					// line, as DWARF does without inlined subroutines;
					// StackTable, Dwarf)
					x.pos = c.pos != 0 ? c.pos : i.pos;
					x.f = i.f;
					x.size = i.size;
					x.signed = i.signed;
					x.sym = i.sym;
					x.mem = i.mem;
					x.release = i.release;
					x.noReturn = i.noReturn;
					x.returnsTwice = i.returnsTwice;
					x.keepsFrame = i.keepsFrame && !f.blocksHere;
					x.variadic = i.variadic;
					x.argTys = i.argTys;
					x.cCall = i.cCall;
					x.cSizes = i.cSizes;
					x.cGroups = i.cGroups;
					x.structRet = i.structRet;
					x.cRet = i.cRet;
					x.cases = i.cases;
					x.args = i.args.map(v -> m(v));
					x.targets = i.targets.map(t -> bmap[t.id]);
					if (i.op == StackAddr) x.imm = i.imm + slotBase;
					x.block = nb;
					if (i.op == Ret) {
						// a jump to the rest of the caller's block
						rets.push({block: nb, v: x.a});
						x.op = Jmp;
						x.ty = Void;
						x.a = -1;
						x.targets = vector(tail);
						nb.succs = [tail];
					}
					nb.ins.push(x);
				}
			}
			// into the callee
			var j = new MIns(Jmp, Void);
			j.id = f.vals.length;
			f.vals.push(j);
			j.block = b;
			var entry = bmap[g.entry.id];
			j.targets = vector(entry);
			b.ins.push(j);
			b.succs = [entry];
			entry.preds.push(b);
			tail.preds = [for (r in rets) r.block];
			// the result
			if (c.ty != Void) {
				if (rets.length == 1) {
					replFrom.push(c.id);
					replTo.push(rets[0].v);
				} else if (rets.length > 1) {
					var phi = new MIns(Phi, c.ty);
					phi.id = f.vals.length;
					f.vals.push(phi);
					phi.block = tail;
					phi.args = rets.mapToVector(r -> r.v);
					tail.ins.unshift(phi);
					replFrom.push(c.id);
					replTo.push(phi.id);
				}
			}
			c.dead = true;
			for (s in site.callee.sites)
				if (s.call.id < vmap.length && vmap[s.call.id] >= 0) more.push({call: f.vals[vmap[s.call.id]], fn: s.fn});
			// a later site in the same block now lives in the tail
		}
		prune(f);
		// uses of the calls' results
		if (replFrom.length == 0) return [for (m in more) if (!m.call.dead && m.call.block != null) m];
		var repl = MFunc.ints(f.vals.length, -1);
		for (q in 0...replFrom.length)
			repl[replFrom[q]] = replTo[q];
		inline function r(v:Int):Int {
			if (v < 0) return v;
			while (repl[v] >= 0)
				v = repl[v];
			return v;
		}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.a >= 0) i.a = r(i.a);
				if (i.b >= 0) i.b = r(i.b);
				if (i.c >= 0) i.c = r(i.c);
				for (q in 0...i.args.length)
					i.args[q] = r(i.args[q]);
			}
		return [for (m in more) if (!m.call.dead && m.call.block != null) m];
	}
}

typedef Template = {mf:MFunc, sites:Array<{call:MIns, fn:FuncInfo}>, size:Int};

