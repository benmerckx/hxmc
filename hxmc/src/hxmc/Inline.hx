package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Inlining of small functions into their callers, on Mir (after MirBuild,
// before Opt): the callee's blocks are copied in place of the call, its
// parameters replaced by the arguments, its returns by jumps to the rest of
// the caller's block (a phi joins the results).
//
// Candidates are decided on hxmc's IR (hxmc.ir) (`candidate`: no try, a small body),
// so that Fingerprint can put a candidate's body into the key of every
// module calling it; the final decision is on the callee's Mir: few
// instructions on its fast path (its inline caches become the caller's; a
// shadow-stack frame stays the copy's own: it pushes and pops it).
class Inline {
	public static inline var MAX_IR = 40; // IR nodes of a candidate
	// instructions outside slow paths: of a callee inlined anywhere, at a
	// call in a loop, and of the runtime's Haxe functions (hxmc.rt) outside
	// loops: 3, those no bigger than their call (Bytes.get, set and length:
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
	// slots would be taken to keep their values (MIns.keepsFrame)
	public static function candidate(f:FuncInfo):Bool {
		if (f.hasTry || f.collects) return false;
		var n = 0;
		function ex(e:Ex) {
			if (++n > MAX_IR) return;
			hxmc.ir.Facts.iterEx(ex, e);
		}
		function st(s:Stmt) {
			if (s.match(SPos(_))) return; // (-debug: the same decisions)
			if (++n > MAX_IR) return;
			hxmc.ir.Facts.iterStmt(st, ex, s);
		}
		for (s in f.body) {
			st(s);
			if (n > MAX_IR) return false;
		}
		return true;
	}

	// the callee's Mir when it can be inlined (built once per caller module)
	public static function template(mb:MirBuild, mf:MFunc):Null<Template> {
		// (a callee with a shadow-stack frame keeps it: its copy pushes and pops it)
		var n = 0;
		for (b in mf.blocks)
			if (!b.cold)
				for (i in b.ins) {
					if (i.op == Call && i.returnsTwice) return null;
					// (constants and addresses fold into their users)
					if (i.op != Const && i.op != ConstF && i.op != SymAddr && i.op != StackAddr && i.op != Param) n++;
				}
		return n <= MAX_LOOP ? {mf: mf, sites: mb.inlineSites, size: n, icSym: mb.icSym, icaches: mb.icaches} : null;
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

	// the blocks of f in loops (a back edge in reverse postorder closes a
	// loop over the blocks between): marked with the mark returned
	public static function loopBlocks(f:MFunc):Int {
		var seen = f.newMark();
		var stack = [f.entry], idx = [0];
		f.entry.mark = seen;
		var post = [];
		while (stack.length > 0) {
			var top = stack.length - 1;
			var b = stack[top];
			if (idx[top] < b.succs.length) {
				var s = b.succs[idx[top]++];
				if (s.mark != seen) {
					s.mark = seen;
					stack.push(s);
					idx.push(0);
				}
			} else {
				stack.pop();
				idx.pop();
				post.push(b);
			}
		}
		post.reverse();
		var n = post.length;
		for (k in 0...n)
			post[k].tmp = k;
		var inLoop = MFunc.ints(n, 0);
		for (k in 0...n)
			for (p in post[k].preds) {
				if (p.mark != seen) continue;
				var pk = p.tmp;
				if (pk >= k)
					for (q in k...pk + 1)
						inLoop[q] = 1;
			}
		var m = f.newMark();
		for (k in 0...n)
			if (inLoop[k] != 0) post[k].mark = m;
		return m;
	}

	// replaces each call (in f) by a copy of its callee's template
	// (returns the calls to candidates in the copies: inlined in turn, to a depth)
	public static function run(f:MFunc, sites:Array<{call:MIns, callee:Template}>, ic:IcAlloc):Array<{call:MIns, fn:FuncInfo}> {
		var more = [];
		if (sites.length == 0) return more;
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
			var icBase = ic.count;
			ic.count += site.callee.icaches;
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
					x.pos = i.pos;
					x.f = i.f;
					x.size = i.size;
					x.signed = i.signed;
					x.sym = i.sym;
					x.mem = i.mem;
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
					if (i.op == SymAddr && i.sym == site.callee.icSym) {
						x.sym = ic.sym;
						x.imm = i.imm + Abi.IC_SIZE * icBase;
					}
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

typedef Template = {mf:MFunc, sites:Array<{call:MIns, fn:FuncInfo}>, size:Int, icSym:String, icaches:Int};

// the caller's inline caches: copies of a callee's get their own entries
typedef IcAlloc = {sym:String, count:Int};
