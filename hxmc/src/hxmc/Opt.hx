package hxmc;

import haxe.ds.Vector;
import hxmc.Mir;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Machine-independent optimizations on MIR (target facts stay in Abi and
// the instruction selectors):
//  - redundancy elimination (global value numbering over the dominator
//    tree): a pure operation, or a load, equal to one in a dominating
//    position is replaced by it. Loads also need the same version of the
//    memory they read: memory is told apart by class (MIns.mem, set by
//    MirBuild: array headers, elements, object fields, globals,
//    shadow-stack slots, memory only calls change, immutable memory); a
//    store or call that may write a class gives it a new version, and so
//    does a join where the predecessors disagree, or a loop header whose
//    loop writes it. A load of the address a dominating store wrote, in
//    the version the store left, takes the stored value.
//  - dead code: pure operations and loads nothing uses.
//  - branches decided by a dominating branch on the same comparison.
//  - loop-invariant code motion: pure operations, and loads that cannot
//    fault of memory the loop does not write, move to a block before the
//    loop.
// It runs on object-level Mir, before MemLower (docs/plans/codegen.md,
// "Object-level Mir"): a field read (GetField) is a load of its field's
// class, a field write (SetField, InitField) a store that answers it, an
// array's length and elements loads of theirs; type tests and enum tags are
// pure; an operation that may collect or call writes every class (a call's
// effect); null tests dominated by one of the same value, or by a branch on
// it, go. What the lowering of an operation reads that others read too
// becomes its operands first (operands: shared and hoisted as any value),
// and a reference stored into an object allocated since the last point
// where a collection may happen loses its write barrier (freshTargets).
// After MemLower only the CFG's cleanup, copies and dead code (lowered).
class Opt {
	// memory classes (MIns.mem)
	public static inline var MOther = 0; // anything: written by any store or call
	public static inline var MHdr = 1; // array headers (length, kind, storage)
	public static inline var MElem = 2; // array elements
	public static inline var MField = 3; // object fields
	public static inline var MGlobal = 4; // global variables
	public static inline var MCallOnly = 5; // changed only by calls (rt_globals, the nursery bounds, inline caches)
	public static inline var MFrame = 6; // shadow-stack slots (calls may move what they hold)
	public static inline var MConst = 7; // never written (type tables, string and NativeArray lengths, object type indices)
	public static inline var MInit = 8; // stores initializing a fresh object (no load can see it before)
	static inline var MTls = 9; // thread-local variables (TlsLoad)
	// object fields by displacement (8 buckets): a field store at one
	// offset leaves loads at other offsets alone (objects do not overlap; a
	// type-correct program reads a field at its own offset); MField's own
	// version is that of fields at dynamic offsets (anonymous objects)
	static inline var MFieldAt = 10;
	// the runtime's thread-locals the code uses most, apart (distinct
	// variables: a store to one leaves loads of the others alone)
	static inline var MTlsSp = 18; // rt_sp
	static inline var MTlsHw = 19; // rt_sp_hw
	static inline var MTlsYp = 20; // rt_young_ptr
	static inline var MTlsYl = 21; // rt_young_limit, rt_young_rlimit
	// shadow-stack slots by displacement (8 buckets), as fields: a store to
	// one slot leaves the loads of the others alone (MFrame's own version:
	// accesses at dynamic offsets)
	static inline var MFrameAt = 22;
	// WasmGC's locals out of SSA (VarGet, VarSet: written by their stores only)
	static inline var MVar = 30;
	static inline var NCLS = 31;
	static inline var TLS_BITS = (1 << MTls) | (1 << MTlsSp) | (1 << MTlsHw) | (1 << MTlsYp) | (1 << MTlsYl);

	static function tlsClass(sym:String):Int
		return switch sym {
			case "rt_sp": MTlsSp;
			case "rt_sp_hw": MTlsHw;
			case "rt_young_ptr": MTlsYp;
			case "rt_young_limit" | "rt_young_rlimit": MTlsYl;
			case _: MTls;
		};
	static inline var FIELD_BITS = ((1 << 8) - 1) << MFieldAt;
	static inline var FRAME_BITS = ((1 << 8) - 1) << MFrameAt;

	// runtime functions that write no memory the code reads and do not collect
	static var readOnly = [
		"hx_aget_i_slow" => true, "hx_aget_f_slow" => true, "hx_aget_l_slow" => true, "rt_write_barrier" => true, "hxmc_barrier_slow" => true
	];

	var f:MFunc;
	var repl:Vector<Int>;
	var ver:Vector<Int>; // per load: the version of its memory class

	public function new(f:MFunc) {
		this.f = f;
	}

	public function run() {
		if (!f.gc) operands();
		simplifyCfg();
		var cfg = f.cfg();
		if (cfg.size == 0) return;
		repl = MFunc.iota(f.vals.length);
		// copies are their operand
		for (bb in f.blocks)
			for (i in bb.ins)
				if (i.op == Copy && !i.dead) {
					repl[i.id] = i.a;
					i.dead = true;
				}
		ver = MFunc.ints(f.vals.length, 0);
		// (functions with a try: a handler block, reached by setjmp's second
		// return, starts with new memory versions, so no load from before
		// is reused there; values computed before setjmp are immutable and
		// live across it in memory or callee-saved registers)
		{
			versions(cfg);
			canonicalize();
			gvn(cfg);
			forwardStores();
		}
		rewrite();
		dce();
		var rounds = 0;
		while (rounds++ < 3 && condProp()) {
			pruneBlocks();
			mergeBlocks();
			// (a branch made a jump can leave a join's phi used by its
			// branch alone: thread it, which can make branches known again)
			simplifyCfg();
			dce();
		}
		if (nullsDropped) dce();
		if (licmOn)
			for (_ in 0...3)
				if (!licm()) break;
		if (barriers > 0) {
			freshTargets();
			loneBarrierOperands();
		}
	}

	static var licmOn = Sys.getEnv("HXMC_LICM") != "0";

	// ---- loop-invariant code motion

	// A load that cannot fault wherever it moves: of a global variable (the
	// globals table, or a scalar global's own symbol), of immutable memory
	// at a symbol, of runtime state at a symbol, or of a thread-local variable.
	// Runtime state can move only when the loop's calls invalidate it. (Loads
	// through an object dereferenced before the loop move too: licm.)
	static inline function safeLoad(i:MIns, vals:Array<MIns>):Bool
		return i.op == TlsLoad || i.op == Load && (i.mem == MGlobal || (i.mem == MConst || i.mem == MCallOnly) && i.b < 0 && vals[i.a].op == SymAddr);

	// One round, over the loops that hold no loop moved from in this round
	// (the caller repeats: what left an inner loop may then leave its outer
	// one). A loop needs a single predecessor from outside (its edge is
	// split when that block has other successors); what moves keeps its
	// order at the end of that block. Returns whether anything moved.
	function licm():Bool {
		var cfg = f.cfg();
		var order = cfg.rpo;
		var n = order.length;
		if (n < 2) return false;
		cfg.loops();
		var idom = cfg.idom;
		var bodies = cfg.loopBodies();
		var inOrder = number(order);
		var vals = f.vals;
		var body = new Vector<Bool>(n); // (the blocks of the loop, by rpo index)
		// the blocks each object is dereferenced in (a load or store through
		// it, at any displacement): not null there, nor where they dominate
		var derefs = new Map<Int, Array<MBlock>>();
		for (b in order)
			for (i in b.ins)
				if (!i.dead && (i.op == Load || i.op == Store || objDeref(i.op)) && i.a >= 0) {
					var o = baseOf(i.a);
					var l = derefs.get(o);
					if (l == null) derefs.set(o, l = []);
					if (l.length == 0 || l[l.length - 1] != b) l.push(b);
				}
		// whether the object o is dereferenced on every way to the block at,
		// outside the loop
		function derefBefore(o:Int, at:MBlock):Bool {
			var l = derefs.get(o);
			if (l != null)
				for (d in l)
					if (d.mark == inOrder && !body[d.tmp]) {
						var x = at.tmp;
						while (x > d.tmp)
							x = idom[x];
						if (x == d.tmp) return true;
					}
			return false;
		}
		// whether the object o is not null at the end of the block at: just
		// allocated, dereferenced on every way there, or a merge of objects
		// that are on their edges
		function nonNull(o:Int, at:MBlock, depth:Int):Bool {
			if (fresh(o) || derefBefore(o, at)) return true;
			var x = vals[o];
			if (depth > 4 || x.op != Phi || x.block == null || x.block.mark != inOrder || x.args.length == 0) return false;
			var ps = x.block.preds;
			for (k in 0...x.args.length)
				if (ps[k].mark != inOrder || !nonNull(baseOf(x.args[k]), ps[k], depth + 1)) return false;
			return true;
		}
		var inv:Array<Bool> = [];
		var moved = false;
		var nextBlock = 0;
		for (b in f.blocks)
			if (b.id >= nextBlock) nextBlock = b.id + 1;
		var made = false;
		var k = n;
		while (k-- > 1) { // inner loops first: their headers come later
			var h = order[k];
			if (h.handler) continue;
			// the loop (Cfg), its blocks in reverse postorder
			var ks = bodies[k];
			if (ks == null) continue;
			body.fill(false);
			var members = [for (x in ks) order[x]];
			var ok = true;
			for (b in members) {
				body[b.tmp] = true;
				if (b != h)
					for (p in b.preds)
						if (p.mark != inOrder) ok = false; // a block made this round (a loop inside already moved from)
			}
			if (!ok) continue;
			// the single way in
			var outside:Null<MBlock> = null, nOut = 0;
			for (p in h.preds)
				if (p.mark != inOrder || !body[p.tmp]) {
					outside = p;
					nOut++;
				}
			if (nOut != 1 || outside.mark != inOrder) continue;
			// what the loop may write; a loop with calls is left alone (what
			// would leave it is cheap to compute again, and would stay live
			// across the calls: a callee-saved register or a reload)
			var kills = 0;
			var calls = false;
			for (b in members)
				for (i in b.ins)
					if (!i.dead) {
						kills |= killMask(i);
						if ((i.op == Call || objCall(i.op)) && !b.cold) calls = true;
					}
			if (calls) continue;
			// the movable instructions, in reverse postorder of their blocks
			var hoist:Array<MIns> = [];
			if (inv.length < vals.length) inv.resize(vals.length);
			inline function invariant(v:Int):Bool
				return v < 0 || inv[v] || {
					var d = vals[v].block;
					d == null || d.mark != inOrder || !body[d.tmp];
				};
			for (b in members)
				for (i in b.ins) {
					if (i.dead) continue;
					var can = switch i.op {
						case Const | ConstF | SymAddr | StackAddr: true;
						case Cmp: false; // (fused with its branch)
						// (object-level: as the loads of fields, headers and immutable memory below)
						case GetField | ArrayLength | NArrayLength:
							var c = objLoadClass(i);
							c >= 0 && kills & (1 << c) == 0 && nonNull(baseOf(i.a), outside, 0);
						case EnumTag: nonNull(baseOf(i.a), outside, 0);
						case TypeTest | FieldAddr: true;
						case _ if (i.isObj()): false;
						case Load | TlsLoad:
							safeLoad(i, vals) && kills & (1 << (i.op == TlsLoad ? tlsClass(i.sym) : i.mem)) == 0
							// (a field, an array's header or immutable memory of an object the
							// loop does not write there, dereferenced before it: not null, so
							// the load cannot fault before the loop; a loop that may collect
							// writes them all: no reference leaves it to live across a GC point)
							|| i.op == Load && i.b < 0 && (i.mem == MField || i.mem == MHdr || i.mem == MConst)
							&& kills & (1 << memClass(i)) == 0 && nonNull(baseOf(i.a), outside, 0);
						case op: pure(op);
					};
					if (!can || !invariant(i.a) || !invariant(i.b) || !invariant(i.c)) continue;
					inv[i.id] = true;
					hoist.push(i);
				}
			// (inv: what leaves this loop)
			for (i in hoist)
				inv[i.id] = false;
			// only constants: nothing worth a block
			var worth = false;
			for (i in hoist)
				if (i.op != Const && i.op != ConstF && i.op != SymAddr && i.op != StackAddr) worth = true;
			if (!worth) continue;
			// the block before the loop
			var pre = outside;
			if (outside.succs.length != 1) {
				var t = outside.term();
				var count = 0;
				for (x in t.targets)
					if (x == h) count++;
				if (count != 1 || t.op == Switch || t.op == AnonTest) continue;
				pre = new MBlock(nextBlock++);
				pre.cold = h.cold && outside.cold;
				pre.sealed = pre.filled = true;
				var j = new MIns(Jmp, Void);
				j.id = vals.length;
				vals.push(j);
				j.block = pre;
				j.targets = vector(h);
				pre.ins = [j];
				pre.preds = [outside];
				pre.succs = [h];
				for (q in 0...t.targets.length)
					if (t.targets[q] == h) t.targets[q] = pre;
				for (q in 0...outside.succs.length)
					if (outside.succs[q] == h) outside.succs[q] = pre;
				for (q in 0...h.preds.length)
					if (h.preds[q] == outside) h.preds[q] = pre;
				f.blocks.push(pre);
				made = true;
			}
			// move
			var term = pre.ins.pop();
			for (i in hoist) {
				i.block.ins.remove(i);
				i.block = pre;
				pre.ins.push(i);
			}
			pre.ins.push(term);
			moved = true;
		}
		if (made) f.edited();
		return moved;
	}

	// whether v is an object just allocated (MemLower.alloc's result: the
	// nursery's bump, ptr + 8, or the slow path's call; a merge of those):
	// never null
	function fresh(v:Int, depth = 0):Bool {
		if (v < 0 || depth > 8) return false;
		var x = f.vals[v];
		switch x.op {
			case Copy:
				return fresh(x.a, depth + 1);
			case New | NewDyn | NewArray | NewNArray:
				return true;
			case Add:
				var p = f.vals[x.a], c = f.vals[x.b];
				return p.op == TlsLoad && p.sym == "rt_young_ptr" && c.op == Const && c.sym == null && c.imm == 8;
			case Call:
				return x.sym != null && (StringTools.startsWith(x.sym, MemLower.ALLOC_STUB) || x.sym == "hxmc_alloc_slow");
			case Phi:
				for (a in x.args)
					if (!fresh(a, depth + 1)) return false;
				return x.args.length > 0;
			case _:
				return false;
		}
	}

	// ---- conditions known from dominating branches

	// A branch on a comparison already decided on the way (a block reached
	// only through one edge of a branch on the same comparison, or on its
	// negation, dominates it) is a jump: the repeated tests of an array's
	// element kind, of a value against null. Returns whether a branch changed.
	function condProp():Bool {
		var cfg = f.cfg();
		var order = cfg.rpo;
		var n = order.length;
		if (n < 3) return false;
		cfg.dom();
		var childHead = cfg.childHead, childNext = cfg.childNext;
		var vals = f.vals;
		// the facts in force: comparison (cond, a, b) is `val`
		var fc:Array<Int> = [], fa:Array<Int> = [], fb:Array<Int> = [], fv:Array<Bool> = [];
		var changed = false;
		var stack = [0], state = [0], depth:Array<Int> = [];
		while (stack.length > 0) {
			var top = stack.length - 1;
			var bk = stack[top];
			var b = order[bk];
			if (state[top] == 0) {
				state[top] = 1;
				depth.push(fc.length);
				if (b.preds.length == 1) {
					var p = b.preds[0];
					var t = p.term();
					if (t != null && t.op == Br && t.targets[0] != t.targets[1]) {
						var c = vals[t.a];
						if (c.op == Cmp && !c.dead) {
							fc.push(c.imm);
							fa.push(c.a);
							fb.push(c.b);
							fv.push(b == t.targets[0]);
						} else if (!c.dead) {
							// (any other value: whether it is not 0)
							fc.push(-1);
							fa.push(t.a);
							fb.push(-1);
							fv.push(b == t.targets[0]);
						}
					}
				}
				// (object-level: null tests already made or decided)
				for (i in b.ins)
					if (i.op == NullCheck && !i.dead) {
						if (knownNonNull(i.a, fc, fa, fb, fv)) {
							i.dead = true;
							nullsDropped = true;
						} else {
							fc.push(NONNULL);
							fa.push(i.a);
							fb.push(-1);
							fv.push(true);
						}
					}
				var t = b.term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1] && fc.length > 0) {
					var c = vals[t.a];
					{
						var known = 0; // 1 true, 2 false
						var k = fc.length;
						while (k-- > 0 && known == 0) {
							if (fc[k] == NONNULL) {
								// (a comparison of that value with null)
								if (c.op == Cmp && isEqNe(c.imm) && (c.a == fa[k] && isZero(c.b) || c.b == fa[k] && isZero(c.a)))
									known = c.imm == (CNe : Int) ? 1 : 2;
								continue;
							}
							if (fc[k] == -1 || c.op != Cmp) {
								if (fc[k] == -1 && fa[k] == t.a) known = fv[k] ? 1 : 2;
								continue;
							}
							var same = fa[k] == c.a && fb[k] == c.b;
							var swapped = fa[k] == c.b && fb[k] == c.a;
							if (same && fc[k] == c.imm) known = fv[k] ? 1 : 2;
							else if ((same || swapped) && isEqNe(fc[k]) && isEqNe(c.imm)) {
								// x == y against y != x, x != y, ...
								known = (fv[k] == (fc[k] == c.imm)) ? 1 : 2;
							}
						}
						if (known != 0) {
							var keep = known == 1 ? t.targets[0] : t.targets[1];
							var drop = known == 1 ? t.targets[1] : t.targets[0];
							var q = drop.preds.indexOf(b);
							if (q >= 0) {
								drop.preds.splice(q, 1);
								for (i in drop.ins)
									if (i.op == Phi) i.removeArg(q);
							}
							t.op = Jmp;
							t.a = -1;
							t.targets = vector(keep);
							b.succs = [keep];
							changed = true;
						}
					}
				}
				var ch = childHead[bk];
				while (ch >= 0) {
					stack.push(ch);
					state.push(0);
					ch = childNext[ch];
				}
			} else {
				stack.pop();
				state.pop();
				var m = depth.pop();
				fc.resize(m);
				fa.resize(m);
				fb.resize(m);
				fv.resize(m);
			}
		}
		if (changed) f.edited();
		return changed;
	}

	var nullsDropped = false;

	static inline function isEqNe(c:Int):Bool
		return c == (CEq : Int) || c == (CNe : Int);

	// the blocks in the order marked with the mark returned, tmp their index
	function number(order:Vector<MBlock>):Int {
		var inOrder = f.newMark();
		for (k in 0...order.length) {
			order[k].mark = inOrder;
			order[k].tmp = k;
		}
		return inOrder;
	}

	// ---- control flow

	// Jump threading of the blocks that only test a phi of booleans (what
	// `a && b` and `a || b` become): [phi x, (const 0), c = cmp eq|ne x 0,
	// br c], nothing of it used elsewhere. A predecessor whose value is a
	// constant, or known from its own branch on the edge, jumps straight to
	// the target; one that jumps here unconditionally branches on its value.
	// A target's phis get, for the new edge, their operand of the edge from
	// the block (defined above it, so available in the predecessor), unless
	// the predecessor already is the target's (that edge stays).
	// Then a block that jumps to a block with no other predecessor absorbs it.
	function simplifyCfg() {
		// branches on constants are jumps
		for (b in f.blocks) {
			var t = b.term();
			if (t == null || t.op != Br) continue;
			var c = f.vals[t.a];
			if (c.op != Const || c.sym != null || t.targets[0] == t.targets[1]) continue;
			var keep = c.imm != 0 || c.imm2 != 0 ? t.targets[0] : t.targets[1];
			var drop = keep == t.targets[0] ? t.targets[1] : t.targets[0];
			var k = drop.preds.indexOf(b);
			if (k >= 0) {
				drop.preds.splice(k, 1);
				for (i in drop.ins)
					if (i.op == Phi) i.removeArg(k);
			}
			t.op = Jmp;
			t.a = -1;
			t.targets = vector(keep);
			b.succs = [keep];
		}
		knownPhiArgs();
		// (the blocks that may be threaded: a phi first, a branch last)
		var any = false;
		for (b in f.blocks) {
			var n = b.ins.length;
			if (n >= 2 && n <= 4 && b.ins[0].op == Phi && b.ins[n - 1].op == Br) {
				any = true;
				break;
			}
		}
		if (!any) {
			f.edited();
			pruneBlocks();
			mergeBlocks();
			return;
		}
		var uses = MFunc.ints(f.vals.length, 0);
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.a >= 0) uses[i.a]++;
				if (i.b >= 0) uses[i.b]++;
				if (i.c >= 0) uses[i.c]++;
				for (x in i.args)
					uses[x]++;
			}
		var vals = f.vals;
		// (rounds: an edge threaded past a join can leave the phi of the join
		// before it used by its branch alone, as in `a && b && c`)
		var threaded = true, rounds = 0;
		while (threaded && rounds++ < 64) { // (a chain of n terms takes about n rounds)
		threaded = false;
		for (b in f.blocks.copy()) {
			if (b == f.entry || b.handler || b.preds.length == 0 || b.preds.length == 1 && contOf(b.preds[0]) == b) continue;
			var ins = b.ins;
			var n = ins.length;
			if (n < 2 || n > 4) continue;
			var phi = ins[0], br = ins[n - 1];
			if (phi.op != Phi || br.op != Br || uses[phi.id] != 1) continue;
			var onZero:MBlock, onSet:MBlock;
			if (n == 2) {
				// [phi x, br x]
				if (br.a != phi.id) continue;
				onZero = br.targets[1];
				onSet = br.targets[0];
			} else {
				var c = ins[n - 2];
				if (c.op != Cmp || br.a != c.id || uses[c.id] != 1) continue;
				if (c.imm != CEq && c.imm != CNe || c.a != phi.id) continue;
				var z = vals[c.b];
				if (z.op != Const || z.sym != null || z.imm != 0 || z.imm2 != 0) continue;
				if (n == 4 && (ins[1] != z || uses[z.id] != 1)) continue;
				// targets when x is zero / not zero
				onZero = c.imm == CEq ? br.targets[0] : br.targets[1];
				onSet = c.imm == CEq ? br.targets[1] : br.targets[0];
			}
			if (onZero == b || onSet == b || onZero == onSet) continue;
			// (the operands of the phis of target s for a new edge, as b's)
			inline function joins(s:MBlock, p:MBlock):Bool
				return !hasPhi(s) || s.preds.indexOf(p) < 0;
			function addArgs(s:MBlock) {
				var j = s.preds.indexOf(b);
				for (i in s.ins)
					if (i.op == Phi) {
						i.addArg(i.args[j]);
						uses[i.args[j]]++;
					}
			}
			var k = 0;
			while (k < b.preds.length) {
				var p = b.preds[k];
				var v = phi.args[k];
				var t = p.term();
				var known = -1; // 0: zero, 1: set
				var x = vals[v];
				if (x.op == Const && x.sym == null) known = x.imm == 0 && x.imm2 == 0 ? 0 : 1;
				else if (t != null && t.op == Br && t.a == v && t.targets[0] != t.targets[1]) known = t.targets[1] == b ? 0 : 1;
				var to = known == 0 ? onZero : onSet;
				if (known >= 0 && joins(to, p)) {
					addArgs(to);
					retarget(p, b, to);
				} else if (known < 0 && t != null && t.op == Jmp && p.succs.length == 1 && joins(onSet, p) && joins(onZero, p)) {
					// branch on the value here
					addArgs(onSet);
					addArgs(onZero);
					t.op = Br;
					t.a = v;
					t.targets = vector(onSet, onZero);
					p.succs = [onSet, onZero];
					onSet.preds.push(p);
					onZero.preds.push(p);
					uses[v]++;
				} else {
					k++;
					continue;
				}
				// drop the edge into b
				b.preds.splice(k, 1);
				phi.removeArg(k);
				uses[v]--;
				threaded = true;
			}
		}
		}
		f.edited();
		pruneBlocks();
		mergeBlocks();
	}

	// A phi's operand that arrives through a block entered only from a branch
	// on that very value is known there: 0 on the branch's else edge, 1 on its
	// then edge when the value is a boolean (a comparison, 0 or 1, a phi of
	// those): `a || b` returned as a value (phi(a, b)) gets phi(1, b), which
	// leaves a's phi used by its branch alone (threaded below)
	function knownPhiArgs() {
		var vals = f.vals;
		var boolMemo = new Map<Int, Bool>();
		var assumed:Array<Int> = []; // (the phis the query under way took as booleans)
		function isBool(v:Int, depth:Int):Bool {
			var x = vals[v];
			switch x.op {
				case Cmp: return true;
				case Const: return x.sym == null && x.imm2 == 0 && (x.imm == 0 || x.imm == 1);
				case Phi if (depth < 8):
					var m = boolMemo.get(v);
					if (m != null) return m;
					boolMemo.set(v, true); // (a cycle through phis: assumed, checked by the other operands)
					assumed.push(v);
					var r = true;
					for (a in x.args)
						if (!isBool(a, depth + 1)) {
							r = false;
							break;
						}
					boolMemo.set(v, r);
					return r;
				case _: return false;
			}
		}
		// (a phi found a boolean while a phi of its cycle was only assumed one
		// is not one when that one is not: `a = c ? a : 5` in a loop makes the
		// loop's phi(1, a) no boolean, yet a query of a found it one; a query
		// that fails forgets the phis it found booleans)
		function isBoolQuery(v:Int):Bool {
			var r = isBool(v, 0);
			if (!r)
				for (a in assumed)
					if (boolMemo.get(a) == true) boolMemo.remove(a);
			assumed.resize(0);
			return r;
		}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.op != Phi) break;
				if (i.ty != I32) continue;
				for (k in 0...i.args.length) {
					var p = b.preds[k];
					if (p.preds.length != 1 || p.handler) continue;
					var t = p.preds[0].term();
					if (t == null || t.op != Br || t.a != i.args[k] || t.targets[0] == t.targets[1]) continue;
					var known = if (t.targets[1] == p) 0 else if (t.targets[0] == p && isBoolQuery(i.args[k])) 1 else -1;
					if (known < 0) continue;
					var c = new MIns(Const, I32);
					c.id = vals.length;
					vals.push(c);
					c.imm = known;
					c.block = p;
					p.ins.insert(p.term() == null ? p.ins.length : p.ins.length - 1, c);
					i.args[k] = c.id;
				}
			}
	}

	// a block that jumps to a block with no other predecessor absorbs it
	function mergeBlocks() {
		var gone = f.newMark();
		for (b in f.blocks) {
			if (b.mark == gone) continue;
			while (true) {
				var t = b.term();
				if (t == null || t.op != Jmp) break;
				var s = t.targets[0];
				if (s == b || s == f.entry || s.preds.length != 1 || s.handler || s.cold != b.cold || contOf(b) == s) break;
				// phis of a single predecessor are their operand
				var rest = [];
				for (i in s.ins)
					if (i.op == Phi) {
						i.op = Copy;
						i.a = i.args[0];
						i.args = vector();
						i.block = b;
						rest.push(i);
					} else {
						i.block = b;
						rest.push(i);
					}
				b.ins.pop();
				for (i in rest)
					b.ins.push(i);
				b.succs = s.succs;
				for (x in s.succs)
					for (q in 0...x.preds.length)
						if (x.preds[q] == s) x.preds[q] = b;
				s.ins = [];
				s.preds = [];
				s.succs = [];
				s.mark = gone;
				f.edited();
			}
		}
		f.blocks = [for (b in f.blocks) if (b.mark != gone) b];
	}

	static inline function hasPhi(b:MBlock):Bool
		return b.ins.length > 0 && b.ins[0].op == Phi;

	// p's edge to `from` goes to `to` (no phis there) instead
	function retarget(p:MBlock, from:MBlock, to:MBlock) {
		var t = p.term();
		for (q in 0...t.targets.length)
			if (t.targets[q] == from) t.targets[q] = to;
		for (q in 0...p.succs.length)
			if (p.succs[q] == from) p.succs[q] = to;
		to.preds.push(p);
		// a branch with both edges to one block is a jump
		if (t.op == Br && t.targets[0] == t.targets[1]) {
			t.op = Jmp;
			t.a = -1;
			t.targets = vector(to);
			p.succs = [to];
			to.preds.remove(p);
		}
	}

	function pruneBlocks() {
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
				while (k >= 0) {
					s.preds.splice(k, 1);
					for (i in s.ins)
						if (i.op == Phi) i.removeArg(k);
					k = s.preds.indexOf(b);
				}
			}
		}
		if (!all) {
			f.blocks = [for (b in f.blocks) if (b.mark == reach) b];
			f.edited();
		}
	}

	// ---- stores

	// Within each block: a load of an object field just stored gets the
	// stored value; a store overwritten before anything could read it
	// (typically the zeroing of a new object's slots, then its
	// initialization) is dropped. A call ends what is known (it may read, or
	// collect: the zeroing is what a collection would see).
	// an address as base + constant (a slot address o + 8k is o, 8k)
	function baseOf(a:Int):Int {
		var x = f.vals[res(a)];
		if (x.op == Add && x.ty == I64) {
			var c = f.vals[res(x.b)];
			if (c.op == Const && c.sym == null && c.imm2 == (c.imm < 0 ? -1 : 0)) return cres(x.a);
		}
		return cres(a);
	}

	function dispOf(a:Int):Int {
		var x = f.vals[res(a)];
		if (x.op == Add && x.ty == I64) {
			var c = f.vals[res(x.b)];
			if (c.op == Const && c.sym == null && c.imm2 == (c.imm < 0 ? -1 : 0)) return c.imm;
		}
		return 0;
	}

	function forwardStores() {
		var vals = f.vals;
		for (b in f.blocks) {
			// the last store per (base, disp, size) of fields and new objects
			var keyBase:Array<Int> = [], keyDisp:Array<Int> = [], keySize:Array<Int> = [];
			var keyStore:Array<MIns> = [], keySeen:Array<Bool> = [];
			var tlsVal = new Map<String, Int>(); // the value last stored to a thread-local here
			inline function clear() {
				keyBase.resize(0);
				keyDisp.resize(0);
				keySize.resize(0);
				keyStore.resize(0);
				keySeen.resize(0);
			}
			// An access through a base that nothing here went through yet may
			// fault (null: the native targets' fault handler throws,
			// hxmc.rt.Faults), and the stores before it are then seen by
			// whatever handles the exception: they are read there. (The bases
			// gone through, the most recent ones.)
			var through:Array<Int> = [];
			inline function access(base:Int) {
				if (keyBase.length > 0) {
					var op = vals[base].op;
					if (op != SymAddr && op != StackAddr && op != TlsLoad && keyBase.indexOf(base) < 0 && through.indexOf(base) < 0) {
						for (k in 0...keySeen.length)
							keySeen[k] = true;
						if (through.length == 16) through.shift();
						through.push(base);
					}
				}
			}
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case _ if (i.isObj()):
						// (object-level: one that writes ends what is known, one
						// that reads sees the stores before it)
						if (objKill(i) != 0 || i.op == InitField || i.op == ArrayInit || i.op == NArrayInit) {
							clear();
							tlsVal.clear();
						} else
							for (k in 0...keySeen.length)
								keySeen[k] = true;
					case Store if ((i.mem == MInit || i.mem == MField) && i.b < 0):
						var base = baseOf(i.a), d = i.imm + dispOf(i.a), sz = i.size;
						if (i.mem == MField) access(base);
						var k = 0;
						var replaced = false;
						while (k < keyBase.length) {
							if (keyDisp[k] == d && keyBase[k] == base) {
								// the previous store at this address, unread: dead
								if (!keySeen[k] && keySize[k] == sz) keyStore[k].dead = true;
								keyStore[k] = i;
								keySize[k] = sz;
								keySeen[k] = false;
								replaced = true;
								k++;
							} else if (i.mem == MField && (keyDisp[k] == d || keyDisp[k] - d < 8 && d - keyDisp[k] < 8)) {
								// another object may be this one: forget that slot
								keyBase.splice(k, 1);
								keyDisp.splice(k, 1);
								keySize.splice(k, 1);
								keyStore.splice(k, 1);
								keySeen.splice(k, 1);
							} else k++;
						}
						if (!replaced) {
							keyBase.push(base);
							keyDisp.push(d);
							keySize.push(sz);
							keyStore.push(i);
							keySeen.push(false);
						}
					case Store:
						// arrays, globals, frames: other memory (a field store through
						// an index, or unknown memory, ends everything)
						if (i.mem == MOther || i.mem == MField || i.mem == MInit) clear() else access(baseOf(i.a));
					case Load:
						var base = baseOf(i.a);
						var ld = i.imm + dispOf(i.a);
						access(base);
						var hit = false;
						for (k in 0...keyBase.length)
							if (keyBase[k] == base) {
								if (i.b < 0 && keyDisp[k] == ld && keySize[k] == i.size && (i.mem == MField || i.mem == MInit)) {
									var v = keyStore[k].c;
									if (!hit && vals[res(v)].ty == i.ty) {
										repl[i.id] = res(v);
										i.dead = true;
										hit = true;
									} else keySeen[k] = true;
								} else if (i.b >= 0 || keyDisp[k] - ld < 8 && ld - keyDisp[k] < 8) keySeen[k] = true;
							}
						if (i.mem == MOther)
							for (k in 0...keySeen.length)
								keySeen[k] = true;
					case Call:
						if (i.returnsTwice || i.sym == null || !readOnly.exists(i.sym)) {
							clear();
							tlsVal.clear();
						} else
							for (k in 0...keySeen.length)
								keySeen[k] = true;
					case TlsStore:
						tlsVal.set(i.sym, res(i.a));
					case TlsLoad:
						var v = tlsVal.get(i.sym);
						if (v != null) {
							repl[i.id] = v;
							i.dead = true;
						}
					case _:
				}
			}
		}
	}

	inline function res(x:Int):Int {
		if (x < 0) return x;
		while (repl[x] != x)
			x = repl[x];
		return x;
	}

	static inline function pure(op:Op):Bool
		return switch op {
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Rotr | Neg | Not | FAdd | FSub | FMul | FDiv | FNeg | FSqrt | FAbs | Cmp | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits | Select:
				true;
			case _: false;
		};

	// the version class of a field access at a constant offset
	inline function fieldClass(i:MIns):Int
		return MFieldAt + (((i.imm + dispOf(i.a)) >> 3) & 7);

	inline function frameClass(i:MIns):Int
		return MFrameAt + (((i.imm + dispOf(i.a)) >> 3) & 7);

	// the version class of a load or store
	inline function memClass(i:MIns):Int
		return i.b >= 0 ? i.mem : i.mem == MField ? fieldClass(i) : i.mem == MFrame ? frameClass(i) : i.mem;

	// the classes an instruction writes, as a bit set (0: none)
	function killMask(i:MIns):Int {
		if (i.isObj()) return objKill(i);
		return switch i.op {
			case Store:
				switch i.mem {
					case MInit: 0;
					case MOther: ((1 << NCLS) - 1) & ~(1 << MConst) & ~(1 << MCallOnly) & ~TLS_BITS;
					case MField if (i.b < 0): (1 << fieldClass(i)) | (1 << MField) | (1 << MOther);
					case MField: FIELD_BITS | (1 << MField) | (1 << MOther);
					case MFrame if (i.b < 0): (1 << frameClass(i)) | (1 << MFrame) | (1 << MOther);
					case MFrame: FRAME_BITS | (1 << MFrame) | (1 << MOther);
					case c: (1 << c) | (1 << MOther);
				}
			case TlsStore: 1 << tlsClass(i.sym);
			// (one during which nothing collects leaves the shadow-stack slots as they are)
			case Call if (i.returnsTwice || i.sym == null || !readOnly.exists(i.sym)):
				((1 << NCLS) - 1) & ~(1 << MConst) & (i.keepsFrame && !i.returnsTwice ? ~((1 << MFrame) | FRAME_BITS) : -1);
			case _: 0;
		};
	}

	// ---- object-level operations

	// every class but immutable memory (what a call may write)
	static inline var ALL = ((1 << NCLS) - 1) & ~(1 << MConst);

	// a field's byte offset (OInfo.loc: an Int's or Bool's is a 4-byte index; MemLower.access)
	static inline function fieldOff(o:OInfo):Int
		return o.t.match(TRef(_) | TF64 | TI64) ? 8 * o.loc : 4 * o.loc;

	static inline function fieldCls(o:OInfo):Int
		return MFieldAt + ((fieldOff(o) >> 3) & 7);

	// an array element of this type is a reference (its slow path may box: a call)
	static inline function ptrElem(t:hxmc.ir.Ir.Ty):Bool
		return !t.match(TI32 | TBool | TF64 | TI64);

	// the class an object-level read loads from (-1: not one)
	static function objLoadClass(i:MIns):Int
		return switch i.op {
			case GetField if (!i.info.t.match(TVoid)): fieldCls(i.info);
			case ArrayLength: MHdr;
			case NArrayLength: MConst;
			case NArrayGet: MElem;
			case ArrayGet if (!ptrElem(i.info.t)): MElem;
			case VarGet: MVar;
			case _: -1;
		};

	// a field write a later read of the field may take the value of (a local's)
	static inline function objStore(i:MIns):Bool
		return (i.op == SetField || i.op == InitField) && !i.info.t.match(TVoid) || i.op == VarSet;

	// the class an object-level store writes (objStore)
	static inline function storeCls(i:MIns):Int
		return i.op == VarSet ? MVar : fieldCls(i.info);

	// the value an object-level store writes
	static inline function storedValue(i:MIns):Int
		return i.op == VarSet ? i.a : i.b;

	// object-level operations whose value depends on their operands alone
	static inline function objPure(op:Op):Bool
		return op == EnumTag || op == TypeTest || op == FieldAddr;

	// object-level operations whose lowering calls on the fast path (LICM: a call)
	static inline function objCall(op:Op):Bool
		return op == VirtualCall || op == ClosureCall || op == AnonCall || op == NewArray || op == NArrayDyn || op == Box || op == Unbox || op == IrNode;

	// object-level operations that dereference their first operand (LICM: not null after)
	static inline function objDeref(op:Op):Bool
		return switch op {
			case NullCheck | GetField | SetField | InitField | ArrayLength | ArrayGet | ArraySet | ArrayPush | NArrayLength | NArrayGet | NArraySet | EnumTag: true;
			case _: false;
		};

	// what tells apart two operations of one kind on the same operands
	static function okey(i:MIns):Int
		return switch i.op {
			case GetField | SetField | InitField: fieldOff(i.info);
			case VarGet | VarSet: i.info.n;
			case ArrayGet: i.info.flag ? 1 : 0;
			case NArrayGet: i.info.n;
			case TypeTest: i.info.cls.tindex;
			case FieldAddr: i.info.loc;
			case _: 0;
		};

	// the classes an object-level operation writes
	function objKill(i:MIns):Int
		return switch i.op {
			case NullCheck | GetField | FieldAddr | EnumTag | TypeTest | ArrayLength | NArrayLength | NArrayGet | InitField | VarGet | Catch: 0;
			case VarSet: 1 << MVar;
			case ArrayGet: ptrElem(i.info.t) ? ALL : 0;
			case SetField: i.info.t.match(TVoid) ? 0 : (1 << fieldCls(i.info)) | (1 << MField) | (1 << MOther);
			case AnonStore: FIELD_BITS | (1 << MField) | (1 << MOther);
			case NArraySet | ArrayInit | NArrayInit: (1 << MElem) | (1 << MOther);
			case RefStore: ((1 << NCLS) - 1) & ~(1 << MConst) & ~(1 << MCallOnly) & ~TLS_BITS;
			case _: ALL;
		};

	// whether v is not null: just allocated, or known on the way here
	// (condProp's facts: a null test of it, a branch on its comparison with null)
	function knownNonNull(v:Int, fc:Array<Int>, fa:Array<Int>, fb:Array<Int>, fv:Array<Bool>):Bool {
		if (fresh(v)) return true;
		var k = fc.length;
		while (k-- > 0) {
			if (fc[k] == NONNULL) {
				if (fa[k] == v) return true;
				continue;
			}
			if (fc[k] < 0 || fb[k] < 0 || !isEqNe(fc[k])) continue;
			var other = fa[k] == v ? fb[k] : fb[k] == v ? fa[k] : -1;
			if (other >= 0 && isZero(other) && fv[k] == (fc[k] == (CNe : Int))) return true;
		}
		return false;
	}

	static inline var NONNULL = -2; // (condProp: a fact that fa is not null)

	inline function isZero(v:Int):Bool {
		var x = f.vals[v];
		return x.op == Const && x.sym == null && x.imm == 0 && x.imm2 == 0;
	}

	// the block an operation in b continues in (OInfo.cont: MemLower needs the
	// operation, its jump there and the continuation's phis as they are)
	static function contOf(b:MBlock):Null<MBlock> {
		var n = b.ins.length;
		if (n < 2) return null;
		var x = b.ins[n - 2];
		return x.info != null ? x.info.cont : null;
	}

	// whether MemLower stores a reference with the write barrier for i
	static function barriered(i:MIns):Bool {
		var o = i.info;
		return switch i.op {
			case SetField: o.t.match(TRef(_)) && !o.flag;
			case AnonStore: o.t.match(TRef(_));
			case ArraySet | ArrayPush | ArrayInit: ptrElem(o.t);
			case NArrayInit: o.kind == Abi.AK_PTR;
			case NArraySet: o.flag;
			case NArrayDyn: i.c >= 0;
			case RefStore: true;
			case _: false;
		};
	}

	// What MemLower's lowering of an operation reads that other operations
	// may read too becomes operands, loaded or computed before it, which are
	// then shared and moved out of loops as any other value:
	//  - a write barrier's nursery bounds (MemLower.setPtr), its last two
	//    arguments (OInfo.young);
	//  - an Array's header (its kind, length and storage) and its index
	//    widened, for an element read or write or a push: arguments from
	//    OInfo.ops on (MemLower.arrGet, arrSet, arrPush);
	//  - a NativeArray's index widened (its b).
	function operands() {
		var vals = f.vals;
		barriers = 0;
		function ins(op:Op, ty:MTy, b:MBlock, at:Array<MIns>):MIns {
			var x = new MIns(op, ty);
			x.id = vals.length;
			vals.push(x);
			x.block = b;
			at.push(x);
			return x;
		}
		function hdr(b:MBlock, out:Array<MIns>, a:Int, disp:Int, ty:MTy):Int {
			var l = ins(Load, ty, b, out);
			l.a = a;
			l.imm = disp;
			l.imm2 = 1;
			l.size = ty == I32 ? 4 : 8;
			l.mem = MHdr;
			return l.id;
		}
		function sext(b:MBlock, out:Array<MIns>, v:Int):Int {
			var x = ins(SExt, I64, b, out);
			x.a = v;
			return x.id;
		}
		function append(i:MIns, more:Array<Int>) {
			var n = i.args.length;
			var args = new Vector<Int>(n + more.length);
			Vector.blit(i.args, 0, args, 0, n);
			for (k in 0...more.length)
				args[n + k] = more[k];
			i.args = args;
		}
		for (b in f.blocks) {
			var any = false;
			for (i in b.ins)
				if (i.isObj() && (barriered(i) || i.op == ArrayGet || i.op == ArraySet || i.op == ArrayPush || i.op == NArrayGet || i.op == NArraySet))
					any = true;
			if (!any) continue;
			var out = [];
			for (i in b.ins) {
				if (!i.isObj() || i.dead) {
					out.push(i);
					continue;
				}
				var o = i.info;
				switch i.op {
					case ArrayGet | ArraySet | ArrayPush if (o.ops < 0):
						var a = i.a;
						var len = -1;
						if (i.op != ArrayGet || o.flag) {
							var l = ins(ArrayLength, I32, b, out);
							l.a = a;
							l.info = new OInfo();
							len = l.id;
						}
						var kind = hdr(b, out, a, 4, I32), data = hdr(b, out, a, 8, I64);
						o.ops = i.args.length;
						append(i, i.op == ArrayPush ? [kind, data, len] : len < 0 ? [kind, data, sext(b, out, i.b)] : [kind, len, data, sext(b, out, i.b)]);
					case NArrayGet | NArraySet if (vals[i.b].ty == I32):
						i.b = sext(b, out, i.b);
					case _:
				}
				if (barriered(i) && !o.young) {
					var bound = [];
					for (s in ["rt_young_start", "rt_young_end"]) {
						var a = ins(SymAddr, I64, b, out);
						a.sym = s;
						var l = ins(Load, I64, b, out);
						l.a = a.id;
						l.imm2 = 1;
						l.size = 8;
						l.mem = MCallOnly;
						bound.push(l.id);
					}
					var size = ins(Sub, I64, b, out);
					size.a = bound[1];
					size.b = bound[0];
					append(i, [bound[0], size.id]);
					o.young = true;
					barriers++;
				}
				out.push(i);
			}
			b.ins = out;
		}
	}

	var barriers = 0;

	public var freshStores = 0; // (stats: the stores freshTargets took the barrier of)

	// the largest object (slots) the runtime always allocates in the nursery
	// (Gc.allocNow: a quarter of it at most; it is 4 KB at least)
	static inline var YOUNG_SLOTS = 63;

	// A reference stored into an object allocated since the last point where
	// a collection may happen (in the block, or one entered only from such a
	// block) needs no write barrier: the object is young (OInfo.fresh; its
	// store still publishes what it stores, MIns.release).
	function freshTargets() {
		var cfg = f.cfg();
		var order = cfg.rpo;
		var n = order.length;
		var inOrder = number(order);
		var outs = MFunc.ints(n, -1);
		for (k in 0...n) {
			var b = order[k];
			var last = -1; // the object allocated since the last collection point
			if (b.preds.length == 1 && !b.handler) {
				var p = b.preds[0];
				if (p.mark == inOrder && p.tmp < k) last = outs[p.tmp];
			}
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.op == SetField && last >= 0 && i.a == last && i.info.young) {
					i.args = i.args.slice(0, i.args.length - 2);
					i.info.young = false;
					i.info.fresh = true;
					freshStores++;
				}
				if (i.isObj() ? objKill(i) == ALL : i.op == Call && (!i.keepsFrame || i.returnsTwice)) last = -1;
				if (i.op == New && i.info.n <= YOUNG_SLOTS) last = i.id;
			}
			outs[k] = last;
		}
	}

	// A barrier's operands that no other store shares, nor moved out of a
	// loop, go again: MemLower loads them after the store, as it would
	// without them (fewer values live across the store).
	function loneBarrierOperands() {
		var vals = f.vals;
		var uses = MFunc.ints(vals.length, 0);
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.a >= 0) uses[i.a]++;
				if (i.b >= 0) uses[i.b]++;
				if (i.c >= 0) uses[i.c]++;
				for (x in i.args)
					uses[x]++;
			}
		var any = false;
		for (b in f.blocks)
			for (i in b.ins) {
				if (!i.isObj() || i.info == null || !i.info.young) continue;
				var n = i.args.length;
				var ys = vals[i.args[n - 2]], size = vals[i.args[n - 1]];
				if (size.op != Sub || size.block != b || ys.block != b || uses[size.id] != 1 || uses[ys.id] != 2 || size.b != ys.id) continue;
				var ye = vals[size.a];
				if (ye.op != Load || ye.block != b || uses[ye.id] != 1) continue;
				i.args = i.args.slice(0, n - 2);
				i.info.young = false;
				any = true;
			}
		if (any) dce();
	}

	// After MemLower: a block that jumps to one only it enters absorbs it,
	// copies are their operand, dead code goes (no other optimization: the
	// optimizer ran on object-level Mir)
	public static function lowered(f:MFunc) {
		var o = new Opt(f);
		o.simplifyCfg();
		o.repl = MFunc.iota(f.vals.length);
		var any = false;
		for (b in f.blocks)
			for (i in b.ins)
				if (i.op == Copy && !i.dead) {
					o.repl[i.id] = i.a;
					i.dead = true;
					any = true;
				}
		if (any) o.rewrite();
		o.dce();
	}

	var next = 1; // the next fresh version

	// the memory versions: per block in reverse postorder, from its
	// predecessors' (a loop header: new versions of what the loop writes),
	// through its instructions; recorded per load
	function versions(cfg:Cfg<MBlock>) {
		var order = cfg.rpo;
		var n = order.length;
		cfg.loops();
		var inOrder = number(order);
		// per block: the classes it writes
		var kill = new Vector<Int>(n);
		for (k in 0...n) {
			var m = 0;
			for (i in order[k].ins)
				if (!i.dead) m |= killMask(i);
			kill[k] = m;
		}
		// per loop header: the classes its loop writes (Cfg's loops: the
		// blocks that reach a back edge without passing the header, the inner
		// loops' with them; not the blocks between the header and its last
		// back edge in reverse postorder, which can leave out an inner loop's
		// latch and the calls in it)
		var head = cfg.loopHead, parent = cfg.loopParent;
		var loopKill = MFunc.ints(n, 0);
		for (k in 0...n)
			if (head[k] >= 0) loopKill[head[k]] |= kill[k];
		var h = n;
		while (h-- > 0)
			if (head[h] == h && parent[h] >= 0) loopKill[parent[h]] |= loopKill[h];
		var outs = new Vector<Vector<Int>>(n);
		for (k in 0...n) {
			var b = order[k];
			var v:Vector<Int> = null;
			var loop = false;
			var entered = false;
			var mixed = 0; // classes the forward predecessors disagree on, or the loop writes
			for (p in b.preds) {
				if (p.mark != inOrder) continue;
				var pk = p.tmp;
				if (pk >= k) {
					loop = true;
					// (an edge back from a block the header does not dominate: a
					// way into the cycle other than this block)
					if (!cfg.dominates(k, pk)) entered = true;
					continue;
				}
				var o = outs[pk];
				if (v == null) v = o.copy() else
					for (c in 0...NCLS)
						if (v[c] != o[c]) mixed |= 1 << c;
			}
			// (a way into the loop other than its header: every class)
			if (loop) mixed |= entered ? -1 : loopKill[k];
			if (v == null || b.handler) {
				v = new Vector<Int>(NCLS);
				for (c in 0...NCLS)
					v[c] = next++;
			} else {
				for (c in 0...NCLS)
					if (mixed & (1 << c) != 0) v[c] = next++;
			}
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.op == Load) ver[i.id] = v[memClass(i)] else if (i.op == TlsLoad) ver[i.id] = v[tlsClass(i.sym)] else if (i.isObj()) {
					var c = objLoadClass(i);
					if (c >= 0) ver[i.id] = v[c];
				}
				var m = killMask(i);
				if (m != 0)
					for (c in 0...NCLS)
						if (m & (1 << c) != 0) v[c] = next++;
				// (a store: the version it leaves its memory in, that of the loads it can answer)
				if (i.op == Store) ver[i.id] = v[memClass(i)] else if (objStore(i)) ver[i.id] = v[storeCls(i)];
			}
			outs[k] = v;
		}
	}

	// operands compared as values: constants and addresses of the same thing are equal
	var canon:Vector<Int>;

	inline function cres(x:Int):Int
		return x < 0 ? x : canon[res(x)];

	function canonicalize() {
		canon = MFunc.iota(f.vals.length);
		// by a hash of the value, then compared exactly
		var first = new Map<Int, Array<Int>>();
		var vals = f.vals;
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				var h = switch i.op {
					case Const: ((i.ty : Int) * 31 + i.imm) * 31 + i.imm2;
					case SymAddr: 7 * 31 + i.imm;
					case StackAddr: 11 * 31 + i.imm;
					case _: continue;
				};
				if (i.sym != null) h = h * 31 + i.sym.length;
				var l = first.get(h);
				if (l == null) {
					first.set(h, [i.id]);
					continue;
				}
				var hit = -1;
				for (j in l) {
					var y = vals[j];
					if (y.op == i.op && y.ty == i.ty && y.imm == i.imm && y.imm2 == i.imm2 && y.sym == i.sym) {
						hit = j;
						break;
					}
				}
				if (hit >= 0) canon[i.id] = hit else l.push(i.id);
			}
	}

	function same(x:MIns, y:MIns):Bool
		return x.isObj() ? x.op == y.op && x.ty == y.ty && cres(x.a) == cres(y.a) && cres(x.b) == cres(y.b) && cres(x.c) == cres(y.c) && okey(x) == okey(y)
			&& (x.op != TypeTest || x.info.cls == y.info.cls) // (WasmGC: no type indices)
			&& ver[x.id] == ver[y.id] : x.op == y.op && x.ty == y.ty && cres(x.a) == cres(y.a) && cres(x.b) == cres(y.b) && cres(x.c) == cres(y.c) && x.imm == y.imm && x.imm2 == y.imm2
			&& x.size == y.size && x.signed == y.signed && x.sym == y.sym && x.mem == y.mem && ver[x.id] == ver[y.id];

	inline function hash(i:MIns):Int
		return i.isObj() ? hashOf(i.op, i.a, i.b, i.c, okey(i), 0, ver[i.id]) : hashOf(i.op, i.a, i.b, i.c, i.imm, i.imm2, ver[i.id]);

	inline function hashOf(op:Op, a:Int, b:Int, c:Int, imm:Int, imm2:Int, v:Int):Int {
		var h = (op : Int) * 31 + cres(a);
		h = h * 31 + cres(b);
		h = h * 31 + cres(c);
		h = h * 31 + imm;
		h = h * 31 + imm2;
		return h * 31 + v;
	}

	// A store whose value a later load of its address can take: it writes
	// the whole value (no truncation), and not the initialization of a new
	// object (whose stores leave the versions as they are: forwardStores)
	inline function forwards(st:MIns):Bool {
		var t = f.vals[res(st.c)].ty;
		return st.mem != MInit && st.size == (t == I32 ? 4 : 8) && t != Void;
	}

	// load l reads what store st wrote: the same address and size, the
	// memory in the version the store left it in (nothing that may write it
	// between), the stored value of the loaded type
	function answers(st:MIns, l:MIns):Bool
		return cres(st.a) == cres(l.a) && cres(st.b) == cres(l.b) && st.imm == l.imm && st.imm2 == l.imm2 && st.size == l.size && st.sym == l.sym
			&& st.mem == l.mem && ver[st.id] == ver[l.id] && f.vals[res(st.c)].ty == l.ty;

	// a field read that takes the value of a field write st (an object's
	// initialization too: the same object, field and memory version)
	function answersObj(st:MIns, l:MIns):Bool
		return if (st.op == VarSet) l.op == VarGet && st.info.n == l.info.n && ver[st.id] == ver[l.id] && f.vals[res(st.a)].ty == l.ty;
		else l.op == GetField && cres(st.a) == cres(l.a) && fieldOff(st.info) == fieldOff(l.info) && ver[st.id] == ver[l.id] && f.vals[res(st.b)].ty == l.ty;

	// value numbering in a preorder walk of the dominator tree, with a
	// scoped table (entries made in a subtree are undone after it); a store
	// is an entry too, under the key of the load of its address, which then
	// takes the stored value (store-to-load forwarding: a value kept in a
	// shadow-stack slot and read back before the next call)
	function gvn(cfg:Cfg<MBlock>) {
		var order = cfg.rpo;
		cfg.dom();
		var childHead = cfg.childHead, childNext = cfg.childNext;
		// the table: chains of value ids per bucket (the newest first)
		var nv = f.vals.length;
		var size = 64;
		while (size < nv * 2)
			size <<= 1;
		var mask = size - 1;
		var head = MFunc.ints(size, -1);
		var chain = MFunc.ints(nv, -1);
		var log:Array<Int> = []; // value ids added, in order
		var vals = f.vals;
		// iterative preorder: a block is entered, its children walked, then left
		var stack = [0], mark = [0];
		var marks:Array<Int> = [];
		while (stack.length > 0) {
			var top = stack.length - 1;
			var bk = stack[top];
			if (mark[top] == 0) {
				mark[top] = 1;
				marks.push(log.length);
				for (i in order[bk].ins) {
					if (i.dead) continue;
					var op = i.op;
					if (op == Store || objStore(i)) {
						if (op == Store && !forwards(i)) continue;
						var h = op == Store ? hashOf(Load, i.a, i.b, -1, i.imm, i.imm2, ver[i.id]) : op == VarSet ? hashOf(VarGet, -1, -1, -1, i.info.n, 0,
							ver[i.id]) : hashOf(GetField, i.a, -1, -1, fieldOff(i.info), 0, ver[i.id]);
						h = (h ^ (h >>> 15)) * 0x2c1b3c6d;
						var bk = (h ^ (h >>> 12)) & mask;
						chain[i.id] = head[bk];
						head[bk] = i.id;
						log.push(i.id);
						log.push(bk);
						continue;
					}
					// (comparisons are recomputed: they fuse with their branch)
					if (!(pure(op) || op == Load || op == TlsLoad || objPure(op) || objLoadClass(i) >= 0) || op == Cmp) continue;
					if (fold(i)) continue;
					var h = hash(i);
					h = (h ^ (h >>> 15)) * 0x2c1b3c6d;
					var bk = (h ^ (h >>> 12)) & mask;
					var hit = -1;
					var q = head[bk];
					while (q >= 0) {
						var y = vals[q];
						if (y.op == Store) {
							if (op == Load && answers(y, i)) {
								hit = res(y.c);
								break;
							}
						} else if (y.op == SetField || y.op == InitField || y.op == VarSet) {
							if ((op == GetField || op == VarGet) && answersObj(y, i)) {
								hit = res(storedValue(y));
								break;
							}
						} else if (same(i, y)) {
							hit = q;
							break;
						}
						q = chain[q];
					}
					if (hit >= 0) {
						repl[i.id] = hit;
						i.dead = true;
					} else {
						chain[i.id] = head[bk];
						head[bk] = i.id;
						log.push(i.id);
						log.push(bk);
					}
				}
				var c = childHead[bk];
				// push children (reverse order does not matter)
				while (c >= 0) {
					stack.push(c);
					mark.push(0);
					c = childNext[c];
				}
			} else {
				stack.pop();
				mark.pop();
				var m = marks.pop();
				while (log.length > m) {
					var bk = log.pop();
					var id = log.pop();
					head[bk] = chain[id];
				}
			}
		}
	}

	// constant folding: integer arithmetic, extensions and bit casts of
	// constants without a symbol (the instruction becomes the constant;
	// shift counts masked as the instructions do; NaNs left alone)
	function fold(i:MIns):Bool {
		if (i.a < 0) return false;
		var x = f.vals[res(i.a)];
		var y = i.b >= 0 ? f.vals[res(i.b)] : null;
		inline function plain(v:MIns):Bool
			return v != null && v.op == Const && v.sym == null;
		inline function set(lo:Int, hi:Int):Bool {
			i.op = Const;
			i.imm = lo;
			i.imm2 = hi;
			i.a = i.b = i.c = -1;
			return true;
		}
		switch i.op {
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr if (i.ty == I32 && plain(x) && plain(y)):
				var a = x.imm, b = y.imm;
				return set(switch i.op {
					case Add: a + b;
					case Sub: a - b;
					case Mul: a * b;
					case And: a & b;
					case Or: a | b;
					case Xor: a ^ b;
					case Shl: a << (b & 31);
					case Sar: a >> (b & 31);
					case _: a >>> (b & 31);
				}, 0);
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr if (i.ty == I64 && plain(x) && plain(y) && x.ty == I64):
				var a = haxe.Int64.make(x.imm2, x.imm), b = haxe.Int64.make(y.imm2, y.imm), n = y.imm & 63;
				var r = switch i.op {
					case Add: a + b;
					case Sub: a - b;
					case Mul: a * b;
					case And: a & b;
					case Or: a | b;
					case Xor: a ^ b;
					case Shl: a << n;
					case Sar: a >> n;
					case _: a >>> n;
				};
				return set(r.low, r.high);
			case SExt if (plain(x) && x.ty == I32 && i.ty == I64):
				return set(x.imm, x.imm < 0 ? -1 : 0);
			case ZExt if (plain(x) && x.ty == I32 && i.ty == I64):
				return set(x.imm, 0);
			case Trunc if (plain(x) && i.ty == I32):
				return set(x.imm, 0);
			case FToBits if (x.op == ConstF && x.f == x.f):
				return set(haxe.io.FPHelper.doubleLow(x.f), haxe.io.FPHelper.doubleHigh(x.f));
			case BitsToF if (plain(x) && x.ty == I64):
				var v = haxe.io.FPHelper.i64ToDouble(x.imm, x.imm2);
				if (v != v) return false;
				i.op = ConstF;
				i.f = v;
				i.imm = i.imm2 = 0;
				i.a = -1;
				return true;
			case _:
				return false;
		}
	}

	function rewrite() {
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.a >= 0) i.a = res(i.a);
				if (i.b >= 0) i.b = res(i.b);
				if (i.c >= 0) i.c = res(i.c);
				for (k in 0...i.args.length)
					i.args[k] = res(i.args[k]);
			}
	}

	// removes pure operations and loads without uses (to a fixed point)
	function dce() {
		var uses = MFunc.ints(f.vals.length, 0);
		for (b in f.blocks)
			for (i in b.ins)
				if (!i.dead) {
					if (i.a >= 0) uses[i.a]++;
					if (i.b >= 0) uses[i.b]++;
					if (i.c >= 0) uses[i.c]++;
					for (x in i.args)
						uses[x]++;
				}
		var work = [];
		for (b in f.blocks)
			for (i in b.ins)
				if (!i.dead && uses[i.id] == 0 && removable(i)) work.push(i);
		while (work.length > 0) {
			var i = work.pop();
			if (i.dead) continue;
			i.dead = true;
			if (i.a >= 0 && --uses[i.a] == 0 && removable(f.vals[i.a])) work.push(f.vals[i.a]);
			if (i.b >= 0 && --uses[i.b] == 0 && removable(f.vals[i.b])) work.push(f.vals[i.b]);
			if (i.c >= 0 && --uses[i.c] == 0 && removable(f.vals[i.c])) work.push(f.vals[i.c]);
			for (x in i.args)
				if (--uses[x] == 0 && removable(f.vals[x])) work.push(f.vals[x]);
		}
		for (b in f.blocks) {
			var ins = b.ins, k = 0;
			for (i in ins)
				if (!i.dead) ins[k++] = i;
			if (k < ins.length) ins.resize(k);
		}
	}

	static inline function removable(i:MIns):Bool
		return pure(i.op) || objPure(i.op) || objLoadClass(i) >= 0 || i.op == ArrayGet || i.op == Load || i.op == TlsLoad || i.op == Const || i.op == ConstF || i.op == SymAddr || i.op == StackAddr || i.op == Copy || i.op == Phi
			|| i.op == IrNode && i.info.ex != null && i.info.ex.match(EStr(_) | EType(_) | EGlobal(_, _)); // (a literal, a type value or a global read: WasmGC)
}
