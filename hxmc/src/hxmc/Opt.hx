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
//    MirBuild: array headers, elements, object fields, globals (the
//    scalar ones apart: raw memory does not write them, killMask),
//    shadow-stack slots, memory only calls change, immutable memory); a
//    store or call that may write a class gives it a new version, and so
//    does a join where the predecessors disagree, or a loop header whose
//    loop writes it. A load of the address a dominating store wrote, in
//    the version the store left, takes the stored value.
//  - dead code: pure operations and loads nothing uses.
//  - branches decided by a dominating branch on the same comparison, or by
//    the cases of a switch that lead there, and a span's element checks a
//    loop proves (inRange); then, once branches were decided, redundancy
//    elimination again (a load in one of two ways that now dominates its
//    repetition).
//  - jump threading: a join's phi of a constant tested by a branch or a
//    switch, the constant's edge straight to its target.
//  - loop-invariant code motion: pure operations, and loads that cannot
//    fault of memory the loop does not write, move to a block before the
//    loop.
// It runs on object-level Mir, before MemLower (docs/hxmc.md,
// "Pipeline"): a field read (GetField) is a load of its field's
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
	// scalar global variables (an Int, Float, Bool, I64 or Ptr static, at
	// its own symbol), apart from the reference ones (slots of rt_globals,
	// MGlobal's own version): raw memory writes them only through a
	// symbol's address (killMask)
	static inline var MScalar = 31;
	static inline var NCLS = 32;
	static inline var EVERY = -1; // (every class: 32 bits)
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
		"hx_aget_i_slow" => true, "hx_aget_f_slow" => true, "hx_aget_l_slow" => true, "rt_write_barrier" => true, "hxmc_barrier_slow" => true,
		// (inline conversions: no memory at all)
		"hxmc$f64_to_f32" => true, "hxmc$f32_to_f64" => true, "hxmc$f32bits_to_freg" => true, "hxmc$freg_to_f32bits" => true
	];

	var f:MFunc;
	var repl:Vector<Int>;
	var ver:Vector<Int>; // per load: the version of its memory class

	public function new(f:MFunc) {
		this.f = f;
	}

	public function run() {
		operands();
		simplifyCfg();
		var cfg = f.cfg();
		if (cfg.size == 0) return;
		redundancy(cfg);
		// (branches on comparisons of constants: inlined arguments; and a join
		// branching on a phi of a constant, threaded so that condProp reads
		// the comparisons it joins)
		if (cmpFolded || constJoin()) {
			simplifyCfg();
			pruneBlocks();
			mergeBlocks();
			simplifyCfg();
			dce();
		}
		var rounds = 0;
		while (rounds++ < 3 && condProp()) {
			pruneBlocks();
			mergeBlocks();
			// (a branch made a jump can leave a join's phi used by its
			// branch alone: thread it, which can make branches known again)
			simplifyCfg();
			dce();
		}
		// (branches decided: a load in what was one of two ways may now
		// dominate its repetition, a view's read after its caller's test
		// of the same header, TypeView; once more, then the branches again)
		if (rounds > 1) {
			redundancy(f.cfg());
			if (condProp()) {
				pruneBlocks();
				mergeBlocks();
				simplifyCfg();
				dce();
			}
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

	// redundancy elimination (gvn) and store forwarding, then the operands rewritten
	function redundancy(cfg:Cfg<MBlock>) {
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
		versions(cfg);
		canonicalize();
		gvn(cfg);
		forwardStores();
		rewrite();
		dce();
	}

	static var licmOn = true; // (the build's, Options.apply)

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
							safeLoad(i, vals) && kills & (1 << (i.op == TlsLoad ? tlsClass(i.sym) : memClass(i))) == 0
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
				return x.sym != null && (StringTools.startsWith(x.sym, MemLower.ALLOC_STUB) || x.sym == "hxmc_alloc_slow" || x.sym == "hxmc_alloc_slow_raw");
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
		var sets:Array<Array<Int>> = []; // (SWITCH_IN facts' cases, by fb)
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
					} else if (t != null && t.op == Switch && t.targets[t.targets.length - 1] != b) {
						// (a switch's cases: the value is one of those that come here)
						var ks = [for (q in 0...t.cases.length) if (t.targets[q] == b) t.cases[q]];
						if (ks.length > 0) {
							fc.push(SWITCH_IN);
							fa.push(t.a);
							fb.push(sets.length);
							fv.push(true);
							sets.push(ks);
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
				// (a range check of all of a span holds with no fact: fits)
				if (t != null && t.op == Br && t.targets[0] != t.targets[1] && (fc.length > 0 || vals[t.a].op == Cmp && vals[t.a].imm == (CULt : Int))) {
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
							if (fc[k] == SWITCH_IN) {
								if (c.op == Cmp && isEqNe(c.imm)) known = switchCase(c, k, sets[fb[k]], fc, fa, fb, fv);
								continue;
							}
							if (fc[k] == -1 || c.op != Cmp) {
								if (fc[k] == -1 && fa[k] == t.a) known = fv[k] ? 1 : 2;
								continue;
							}
							var same = sameVal(fa[k], c.a) && sameVal(fb[k], c.b);
							var swapped = sameVal(fa[k], c.b) && sameVal(fb[k], c.a);
							if (same && fc[k] == c.imm) known = fv[k] ? 1 : 2;
							else if ((same || swapped) && isEqNe(fc[k]) && isEqNe(c.imm)) {
								// x == y against y != x, x != y, ...
								known = (fv[k] == (fc[k] == c.imm)) ? 1 : 2;
							} else known = implied(fc[k], fa[k], fb[k], fv[k], c);
						}
						if (known == 0 && c.op == Cmp) known = impliedByShift(c, cfg, fc, fa, fb, fv);
						// (a span's element check a loop proves: Mem.spanUlt)
						if (known == 0 && c.op == Cmp && c.imm2 == MIns.SPAN_CHECK && inRange(c, cfg, fc, fa, fb, fv))
							known = c.imm == (CULt : Int) ? 1 : 2;
						// (a range check FnLower made, of a sub, blit or fill)
						if (known == 0 && c.op == Cmp && fits(c, cfg, fc, fa, fb, fv)) known = 2;
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

	// a comparison c of a switch's value with a constant (x == q, x != q)
	// decided by the switch's cases that lead here, ks (fact k), less those
	// a later fact excludes (x != y on the way: `t == 2 || t == 4` in the
	// case of 2 and 4): 1 true, 2 false, 0 unknown
	function switchCase(c:MIns, k:Int, ks:Array<Int>, fc:Array<Int>, fa:Array<Int>, fb:Array<Int>, fv:Array<Bool>):Int {
		var s = fa[k];
		var q = sameVal(c.a, s) ? intConst(c.b) : sameVal(c.b, s) ? intConst(c.a) : null;
		if (q == null) return 0;
		var left = [];
		for (x in ks) {
			var out = false;
			for (j in k + 1...fc.length)
				if ((fc[j] == (CEq : Int) && !fv[j] || fc[j] == (CNe : Int) && fv[j])
					&& (sameVal(fa[j], s) && intConst(fb[j]) == x || sameVal(fb[j], s) && intConst(fa[j]) == x))
					out = true;
			if (!out) left.push(x);
		}
		var eq = left.indexOf(Std.int(q)) < 0 ? 2 : left.length == 1 ? 1 : 0;
		return eq == 0 ? 0 : (eq == 1) == (c.imm == (CEq : Int)) ? 1 : 2;
	}

	// Whether a join branches on a phi with a constant operand: `a || b`,
	// whose `true` the first simplifyCfg saw as a copy
	function constJoin():Bool {
		for (b in f.blocks) {
			var n = b.ins.length;
			if (n < 2 || n > 4 || b.ins[0].op != Phi || b.ins[n - 1].op != Br) continue;
			for (a in b.ins[0].args) {
				var x = f.vals[a];
				if (x.op == Const && x.sym == null) return true;
			}
		}
		return false;
	}

	var nullsDropped = false;
	var cmpFolded = false; // (gvn: a comparison of constants)

	// Whether a signed comparison of an I32 value with a constant, c, is
	// decided by a fact on the same value and another constant (cond, a, b
	// is v): the range the fact leaves the value against c's constant (1
	// true, 2 false, 0 unknown). Haxe.io.Bytes' accesses test length >= n:
	// after `if (b.length < 16) return`, every one of 2, 4 and 8 bytes is
	// decided.
	function implied(cond:Int, a:Int, b:Int, v:Bool, c:MIns):Int {
		var fx = cmpConst(cond, a, b), cx = cmpConst(c.imm, c.a, c.b);
		if (fx == null || cx == null || !sameVal(fx.x, cx.x)) return 0;
		var lo = -2147483648.0, hi = 2147483647.0, k = fx.k;
		switch [fx.cond, v] {
			case [CLt, true] | [CGe, false]: hi = k - 1;
			case [CLt, false] | [CGe, true]: lo = k;
			case [CLe, true] | [CGt, false]: hi = k;
			case [CLe, false] | [CGt, true]: lo = k + 1;
			case [CEq, true] | [CNe, false]:
				lo = k;
				hi = k;
			case _: return 0;
		}
		return decide(cx.cond, lo, hi, cx.k);
	}

	// x cond q for every x in lo .. hi: 1 true, 2 false, 0 either
	static function decide(cond:Int, lo:Float, hi:Float, q:Float):Int
		return switch cond {
			case CLt: hi < q ? 1 : lo >= q ? 2 : 0;
			case CLe: hi <= q ? 1 : lo > q ? 2 : 0;
			case CGt: lo > q ? 1 : hi <= q ? 2 : 0;
			case CGe: lo >= q ? 1 : hi < q ? 2 : 0;
			case CEq: lo == q && hi == q ? 1 : q < lo || q > hi ? 2 : 0;
			case CNe: q < lo || q > hi ? 1 : lo == q && hi == q ? 2 : 0;
			case _: 0;
		}

	// Whether c, a comparison of m with a constant, is decided by m >= 2^j,
	// which a fact x < m >> j for an x never negative gives (a loop to
	// `b.length >> 2` from 0: inside it, b.length >= 4, so each 4-byte
	// access's test of the length goes)
	function impliedByShift(c:MIns, cfg:Cfg<MBlock>, fc:Array<Int>, fa:Array<Int>, fb:Array<Int>, fv:Array<Bool>):Int {
		var cx = cmpConst(c.imm, c.a, c.b);
		if (cx == null) return 0;
		for (k in 0...fc.length) {
			var x = -1, y = -1;
			switch [fc[k], fv[k]] {
				case [CLt, true] | [CGe, false]:
					x = fa[k];
					y = fb[k];
				case [CGt, true] | [CLe, false]:
					x = fb[k];
					y = fa[k];
				case _:
			}
			if (y < 0 || x < 0) continue;
			var sh = f.vals[y];
			if (sh.op != Sar || sh.ty != I32 || !sameVal(sh.a, cx.x) || constOf(sh.b) < 1 || constOf(sh.b) > 30 || !nonNeg(x, cfg, 0)) continue;
			var t = decide(cx.cond, Math.pow(2, constOf(sh.b)), 2147483647.0, cx.k);
			if (t != 0) return t;
		}
		return 0;
	}

	// a signed comparison of an I32 value x with a constant k, as x cond k
	// (the constant on the left: the condition swapped); null for any other
	function cmpConst(cond:Int, a:Int, b:Int):Null<{cond:Int, x:Int, k:Float}> {
		if (a < 0 || b < 0) return null;
		switch cond {
			case CLt | CLe | CGt | CGe | CEq | CNe:
			case _: return null;
		}
		var ka = intConst(a), kb = intConst(b);
		if (kb != null && ka == null && f.vals[a].ty == I32) return {cond: cond, x: a, k: kb};
		if (ka != null && kb == null && f.vals[b].ty == I32)
			return {cond: switch cond {
				case CLt: CGt;
				case CLe: CGe;
				case CGt: CLt;
				case CGe: CLe;
				case c: c;
			}, x: b, k: ka};
		return null;
	}

	// an I32 constant's value (any sign), else null
	function intConst(v:Int):Null<Float> {
		var c = f.vals[v];
		return c.op == Const && c.ty == I32 && c.sym == null ? (c.imm : Float) : null;
	}

	// ---- a span's element checks a loop proves (condProp)

	// Whether a span's element check, ult(i, n) or uge(i, n) (MIns.SPAN_CHECK),
	// is decided: i < n (signed) holds where it is, from the facts in force
	// (directly, or i < x and x <= n, or i <= x and x < n: a loop's bound
	// tested against the span's length), and i is never negative (nonNeg),
	// so i < n unsigned too; or i is x & m (a table's index, m >= 0) and n a
	// constant above m or tested against one. Only the marked checks: spans'
	// elements and haxe.io.Bytes' accesses (Mem.spanUlt).
	function inRange(c:MIns, cfg:Cfg<MBlock>, fc:Array<Int>, fa:Array<Int>, fb:Array<Int>, fv:Array<Bool>):Bool {
		if (c.imm != (CULt : Int) && c.imm != (CUGe : Int)) return false;
		var i = c.a, n = c.b;
		if (f.vals[i].ty != I32) return false;
		var r = relations(fc, fa, fb, fv);
		var lx = r.lx, ly = r.ly, strict = r.strict;
		var lt = false;
		for (k in 0...lx.length) {
			if (lx[k] != i) continue;
			if (ly[k] == n && strict[k]) lt = true;
			else for (j in 0...lx.length)
				if (lx[j] == ly[k] && ly[j] == n && (strict[k] || strict[j])) lt = true;
			if (lt) break;
		}
		if (lt && (nonNeg(i, cfg, 0) || stepped(i, n, cfg))) return true;
		if (strided(i, n, lx, ly, strict, cfg)) return true;
		if (window(i, n, lx, ly, strict, cfg)) return true;
		// (a small block's index: x * s + k with constants s, k >= 0, x never
		// negative and below a constant, against a length of a constant or
		// tested against one: `if (s.length < 64) return; for (c in 0...8)
		// s[c + 56]`)
		{
			var lo = lowerBound(n, lx, ly, strict);
			if (lo > 0) {
				var hi = upperOf(i, cfg, lx, ly, strict, 0);
				if (hi >= 0 && hi < lo) return true;
			}
		}
		// (a table's index: x & m, 0 <= m, against a length of at least m + 1,
		// a constant or tested against one)
		var x = f.vals[i];
		var m = x.op != And ? -1 : constOf(x.b) >= 0 ? constOf(x.b) : constOf(x.a);
		if (m < 0) return false;
		if (constOf(n) > m) return true;
		for (k in 0...lx.length)
			if (ly[k] == n && constOf(lx[k]) >= 0 && (strict[k] ? constOf(lx[k]) >= m : constOf(lx[k]) > m)) return true;
		return false;
	}

	// the signed facts in force as x < y (strict) or x <= y
	static function relations(fc:Array<Int>, fa:Array<Int>, fb:Array<Int>, fv:Array<Bool>):{lx:Array<Int>, ly:Array<Int>, strict:Array<Bool>} {
		var lx:Array<Int> = [], ly:Array<Int> = [], strict:Array<Bool> = [];
		inline function rel(x:Int, y:Int, lt:Bool) {
			lx.push(x);
			ly.push(y);
			strict.push(lt);
		}
		for (k in 0...fc.length) {
			var a = fa[k], b = fb[k], v = fv[k];
			switch fc[k] {
				case CLt: if (v) rel(a, b, true) else rel(b, a, false);
				case CLe: if (v) rel(a, b, false) else rel(b, a, true);
				case CGt: if (v) rel(b, a, true) else rel(a, b, false);
				case CGe: if (v) rel(b, a, false) else rel(a, b, true);
				case CEq | CNe if (v == (fc[k] == (CEq : Int))):
					rel(a, b, false);
					rel(b, a, false);
				case _:
			}
		}
		return {lx: lx, ly: ly, strict: strict};
	}

	// Whether c is a range check FnLower made, ult(sext(n), zext(p) +
	// zext(q)) (p + q > n: a span's sub, blit, fill), that cannot fail where
	// it is: for a constant q = k, p <u n - j with n >= j and j >= k - 1
	// (haxe.io.Bytes' test of a k-byte access, then a view's sub(p, k)), or
	// p < n - j (signed) with p never negative; for any q, p <= n - q with p
	// and q never negative (`pos > length - len` tested); p + q a constant
	// at most n's least value (`if (b.length < 16) return`), or 0 + n (all of
	// it); p = n - j for a constant q = k <= j, n at least j (`if (n >= 8)
	// s.getI64(n - 8)`). p is never negative also as a loop's counter stepping
	// up by s where p < n - c, c >= s - 1, held (`while (i < n - 8) { ...; i +=
	// 8; }`: stepped); p = x + d for a constant d if x < n - j, j >= d + k - 1,
	// holds (a step's second word). A negative n passes it too (sext(n) is at
	// least 2^63), so n - j may wrap there.
	function fits(c:MIns, cfg:Cfg<MBlock>, fc:Array<Int>, fa:Array<Int>, fb:Array<Int>, fv:Array<Bool>):Bool {
		if (c.imm != (CULt : Int)) return false;
		var sn = f.vals[c.a], e = f.vals[c.b];
		if (sn.op != SExt || sn.ty != I64 || f.vals[sn.a].ty != I32) return false;
		var n = sn.a;
		var r = relations(fc, fa, fb, fv);
		// (p + q a constant: n at least that)
		if (e.op == Const && e.ty == I64 && e.sym == null) return e.imm2 == 0 && e.imm >= 0 && lowerBound(n, r.lx, r.ly, r.strict) >= e.imm;
		// (0 + n, all of it: sext(n) < zext(n) never holds, `s.sub(0, s.length)`)
		if (e.op == ZExt && sameVal(e.a, n)) return true;
		if (e.op != Add || e.ty != I64) return false;
		function zextOf(v:Int):Int {
			var x = f.vals[v];
			return x.op == ZExt && f.vals[x.a].ty == I32 ? x.a : -1;
		}
		function konst(v:Int):Int {
			var x = f.vals[v];
			if (x.op == Const && x.ty == I64 && x.sym == null) return x.imm2 == 0 && x.imm >= 0 ? x.imm : -1;
			var z = zextOf(v);
			return z >= 0 ? constOf(z) : -1;
		}
		var p = zextOf(e.a), qv = e.b;
		if (p < 0) {
			p = zextOf(e.b);
			qv = e.a;
		}
		if (p < 0) return false;
		var k = konst(qv), q = zextOf(qv);
		if (k < 0 && q < 0) return false;
		if (constOf(p) == 0 && q >= 0 && sameVal(q, n)) return true;
		function atLeast0(v:Int):Bool
			return nonNeg(v, cfg, 0) || lowerBound(v, r.lx, r.ly, r.strict) >= 0 || stepped(v, n, cfg);
		if (k >= 0) {
			var px = f.vals[p];
			if (px.op == Sub && px.ty == I32 && px.a == n && constOf(px.b) >= k && lowerBound(n, r.lx, r.ly, r.strict) >= constOf(px.b)) return true;
		}
		// (s = n - j, or n: j)
		function less(s:Int):Int {
			if (s == n) return 0;
			var x = f.vals[s];
			return x.op == Sub && x.ty == I32 && x.a == n ? constOf(x.b) : -1;
		}
		if (k >= 0)
			for (i in 0...fc.length) {
				var lt = switch [fc[i], fv[i]] {
					case [CULt, true] | [CUGe, false]: true;
					case [CULe, true] | [CUGt, false]: false;
					case _: continue;
				}
				var j = less(fb[i]);
				if (sameVal(fa[i], p) && j >= (lt ? k - 1 : k) && (j == 0 || lowerBound(n, r.lx, r.ly, r.strict) >= j)) return true;
			}
		// (p = x + d, a constant d >= 0: x < n - j with j >= d + k - 1, the
		// second word of a loop's step)
		var px = f.vals[p], d = 0, base = p;
		if (k >= 0 && px.op == Add && px.ty == I32 && constOf(px.b) >= 0 && constOf(px.b) <= 1 << 16) {
			base = px.a;
			d = constOf(px.b);
		}
		for (i in 0...r.lx.length) {
			if (!sameVal(r.lx[i], p) && !(d > 0 && sameVal(r.lx[i], base))) continue;
			var s = r.ly[i];
			if (k >= 0) {
				var j = less(s), dd = sameVal(r.lx[i], p) ? 0 : d;
				if (j >= (r.strict[i] ? k + dd - 1 : k + dd) && atLeast0(dd == 0 ? p : base)) return true;
			} else {
				var x = f.vals[s];
				if (x.op == Sub && x.ty == I32 && x.a == n && x.b == q && atLeast0(p) && atLeast0(q)) return true;
			}
		}
		return false;
	}

	// whether v (an I32) is never negative as nonNeg finds it, or as a
	// loop's counter stepping by a constant s > 0: v + s computed where a
	// dominating branch found v < n - c with c >= s - 1 (or v <= n - c, c >=
	// s), so v + s <= n, no wrap (n a span's length, never negative); a phi
	// of such counters too (a word loop's end, a byte loop's start)
	function stepped(v:Int, n:Int, cfg:Cfg<MBlock>, depth = 0):Bool {
		var x = f.vals[v];
		if (x.ty != I32 || depth > 4) return false;
		if (x.op == Const) return x.sym == null && x.imm >= 0;
		if (x.op != Phi) return false;
		for (a in x.args) {
			if (a == v) continue;
			var y = f.vals[a];
			var s = y.op == Add && y.ty == I32 ? (y.a == v ? constOf(y.b) : y.b == v ? constOf(y.a) : -1) : -1;
			if (s == 1) {
				if (!belowSome(v, y.block, cfg)) return false;
			} else if (s > 1 && s <= 1 << 16) {
				if (!belowLength(v, y.block, n, s, cfg)) return false;
			} else if (!stepped(a, n, cfg, depth + 1)) return false;
		}
		return true;
	}

	// whether a branch dominating block b found v < n - c (c >= s - 1) or v <= n - c (c >= s)
	function belowLength(v:Int, b:MBlock, n:Int, s:Int, cfg:Cfg<MBlock>):Bool {
		var idom = cfg.idom;
		var k = cfg.index(b);
		inline function less(y:Int):Int {
			var z = f.vals[y];
			return z.op == Sub && z.ty == I32 && z.a == n ? constOf(z.b) : -1;
		}
		while (k > 0) {
			var x = cfg.rpo[k];
			if (x.preds.length == 1) {
				var t = x.preds[0].term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1]) {
					var c = f.vals[t.a];
					var taken = x == t.targets[0];
					if (c.op == Cmp && !c.dead) {
						// (v < y or v <= y, as the branch found it)
						var y = -1, strict = false;
						switch c.imm {
							case CLt if (taken && c.a == v): y = c.b; strict = true;
							case CGe if (!taken && c.a == v): y = c.b; strict = true;
							case CLe if (taken && c.a == v): y = c.b;
							case CGt if (!taken && c.a == v): y = c.b;
							case CGt if (taken && c.b == v): y = c.a; strict = true;
							case CLe if (!taken && c.b == v): y = c.a; strict = true;
							case CGe if (taken && c.b == v): y = c.a;
							case CLt if (!taken && c.b == v): y = c.a;
							case _:
						}
						if (y >= 0) {
							var j = less(y);
							if (j >= 0 && j >= (strict ? s - 1 : s)) return true;
						}
					}
				}
			}
			k = idom[k];
		}
		return false;
	}

	// (a record's index: x * s + k, or x << j + k, s = 2^j, against m - c,
	// constants k, c >= 0 with k + c < s, x never negative and below m >> j:
	// then m >= s, and x * s + k <= m - s + k < m - c; haxe.io.Bytes'
	// `for (i in 0...b.length >> 2) b.getInt32(i * 4)`)
	function strided(i:Int, n:Int, lx:Array<Int>, ly:Array<Int>, strict:Array<Bool>, cfg:Cfg<MBlock>):Bool {
		var v = f.vals[i], k = 0;
		if (v.op == Add && v.ty == I32) {
			k = constOf(v.b);
			if (k < 0) return false;
			v = f.vals[v.a];
		}
		var x = -1, j = -1;
		switch v.op {
			case Shl if (v.ty == I32 && constOf(v.b) >= 1 && constOf(v.b) <= 30):
				x = v.a;
				j = constOf(v.b);
			case Mul if (v.ty == I32):
				var sc = constOf(v.b) > 0 ? constOf(v.b) : constOf(v.a);
				x = constOf(v.b) > 0 ? v.a : v.b;
				for (t in 1...31)
					if (sc == 1 << t) j = t;
			case _:
		}
		if (j < 0) return false;
		var m = n, c = 0, nv = f.vals[n];
		if (nv.op == Sub && nv.ty == I32 && constOf(nv.b) >= 0) {
			m = nv.a;
			c = constOf(nv.b);
		}
		if (k + c >= 1 << j || !nonNeg(x, cfg, 0)) return false;
		for (q in 0...lx.length)
			if (lx[q] == x && strict[q]) {
				var y = f.vals[ly[q]];
				if (y.op == Sar && y.ty == I32 && y.a == m && constOf(y.b) == j) return true;
			}
		return false;
	}

	// (a window's index: p + k, or p, against n, where 0 <= p <= n - m,
	// 0 <= k < m (0 < m for p alone) and m <= n: then n - m cannot wrap, and
	// p + k <= n - 1; m units compared from each p, Str.find's `c[i + k]`.
	// p may be a counter: up from values never negative, or down from
	// values at most n - m)
	function window(i:Int, n:Int, lx:Array<Int>, ly:Array<Int>, strict:Array<Bool>, cfg:Cfg<MBlock>):Bool {
		function holds(x:Int, y:Int, lt:Bool):Bool {
			for (q in 0...lx.length)
				if (sameVal(lx[q], x) && ly[q] == y && (strict[q] || !lt)) return true;
			return false;
		}
		// (tested against a constant >= 0)
		function tested(v:Int):Bool {
			for (q in 0...lx.length)
				if (ly[q] == v && constOf(lx[q]) >= 0) return true;
			return false;
		}
		function nonNegHere(v:Int):Bool {
			if (nonNeg(v, cfg, 0) || tested(v)) return true;
			var x = f.vals[v];
			if (x.op != Phi || x.ty != I32) return false;
			// (an operand as its edge brings it: tested where it leaves its block,
			// not here, which tests this iteration's values)
			for (j in 0...x.args.length) {
				var a = x.args[j];
				if (a == v) continue;
				var y = f.vals[a];
				var up = y.op == Add && (y.a == v && isOne(y.b) || y.b == v && isOne(y.a));
				if (up ? !belowSome(v, y.block, cfg) : !nonNeg(a, cfg, 0) && !nonNegAt(a, x.block.preds[j], cfg)) return false;
			}
			return true;
		}
		// (v <= s, or v < s + 1: no wrap, s = n - m <= n - 1)
		function atMost(v:Int, s:Int):Bool {
			if (holds(v, s, false)) return true;
			for (q in 0...lx.length) {
				var y = f.vals[ly[q]];
				if (lx[q] == v && strict[q] && y.op == Add && (y.a == s && isOne(y.b) || y.b == s && isOne(y.a))) return true;
			}
			var x = f.vals[v];
			if (x.op != Phi || x.ty != I32) return false;
			// (s = n - m the same in every iteration: n and m defined before the
			// phi's block, which a loop's header dominates; each operand at most s
			// where its edge leaves, not where this iteration tests its own; 0
			// is, as m <= n)
			var pb = cfg.index(x.block), sv = f.vals[s];
			inline function before(w:Int):Bool {
				var wb = cfg.index(f.vals[w].block);
				return wb != pb && cfg.dominates(wb, pb);
			}
			if (!before(sv.a) || !before(sv.b)) return false;
			for (j in 0...x.args.length) {
				var a = x.args[j];
				if (a == v) continue;
				var y = f.vals[a];
				var down = y.op == Sub && y.a == v && isOne(y.b) || y.op == Add && (y.a == v && isConst(y.b, -1) || y.b == v && isConst(y.a, -1));
				if (down ? !aboveSome(v, y.block, cfg) : !isConst(a, 0) && !atMostAt(a, s, x.block.preds[j], cfg)) return false;
			}
			return true;
		}
		function at(p:Int, k:Int):Bool {
			if (!nonNegHere(p) || k >= 0 && !nonNegHere(k)) return false;
			for (q in 0...lx.length) {
				var s = f.vals[ly[q]];
				if (s.op == Add && s.ty == I32) s = f.vals[isOne(s.b) ? s.a : s.b];
				if (s.op != Sub || s.ty != I32 || s.a != n || !atMost(p, s.id)) continue;
				var m = s.b;
				if (!holds(m, n, false)) continue;
				if (k >= 0 ? holds(k, m, true) : lowerBound(m, lx, ly, strict) >= 1) return true;
			}
			return false;
		}
		var x = f.vals[i];
		if (x.op == Add && x.ty == I32) return at(x.a, x.b) || at(x.b, x.a);
		return at(i, -1);
	}

	// the least value n (an I32) has where the facts hold: a constant, or a
	// constant c with c <= n (c < n: c + 1), or m - k for a constant k >= 0
	// with m's least value at least k (no wrap: haxe.io.Bytes' length - 3 of a
	// 4-byte access); -1: none known
	function lowerBound(n:Int, lx:Array<Int>, ly:Array<Int>, strict:Array<Bool>, depth = 0):Float {
		var x = f.vals[n];
		if (x.op == Sub && x.ty == I32 && constOf(x.b) >= 0 && depth < 2) {
			var m = lowerBound(x.a, lx, ly, strict, depth + 1);
			if (m >= constOf(x.b)) return m - constOf(x.b);
		}
		var best:Float = constOf(n);
		for (k in 0...lx.length)
			if (ly[k] == n) {
				var c = constOf(lx[k]);
				if (c >= 0 && c + (strict[k] ? 1 : 0) > best) best = c + (strict[k] ? 1 : 0);
			}
		return best;
	}

	// the greatest value v (an I32) can have where the facts hold, when it
	// is never negative: a constant; x below a constant (x never negative);
	// x + k, x * k, x << k for a constant k >= 0 (computed without wrapping:
	// above 2^31 - 1 counts as unknown); -1: unknown
	function upperOf(v:Int, cfg:Cfg<MBlock>, lx:Array<Int>, ly:Array<Int>, strict:Array<Bool>, depth:Int):Float {
		var x = f.vals[v];
		if (x.ty != I32 || depth > 3) return -1;
		var c = constOf(v);
		if (c >= 0) return c;
		var r:Float = -1;
		switch x.op {
			case Add | Mul | Shl:
				var k = constOf(x.b), y = x.a;
				if (k < 0 && x.op != Shl) {
					k = constOf(x.a);
					y = x.b;
				}
				if (k < 0 || x.op == Shl && k > 30) return -1;
				var u = upperOf(y, cfg, lx, ly, strict, depth + 1);
				if (u < 0) return -1;
				r = switch x.op {
					case Add: u + k;
					case Mul: u * k;
					case _: u * Math.pow(2, k);
				}
			// (x & m for a constant m >= 0: m at most, x of any sign)
			case And if (constOf(x.b) >= 0 || constOf(x.a) >= 0):
				r = constOf(x.b) >= 0 ? constOf(x.b) : constOf(x.a);
			case _:
				if (!nonNeg(v, cfg, 0)) return -1;
				for (k in 0...lx.length)
					if (lx[k] == v) {
						var b = constOf(ly[k]);
						if (b >= 0) {
							var u:Float = strict[k] ? b - 1 : b;
							if (r < 0 || u < r) r = u;
						}
					}
		}
		return r > 2147483647.0 ? -1 : r;
	}

	// an I32 constant's value when it is not negative, else -1
	// whether a and b are one value: the same, or equal integer constants
	// (each access of Bytes tests length >= n with a constant of its own)
	function sameVal(a:Int, b:Int):Bool {
		if (a == b) return true;
		if (a < 0 || b < 0) return false;
		// (through copies: a merged block's phis)
		var x = f.vals[a], y = f.vals[b];
		while (x.op == Copy && x.a >= 0)
			x = f.vals[x.a];
		while (y.op == Copy && y.a >= 0)
			y = f.vals[y.a];
		if (x == y) return true;
		return x.op == Const && y.op == Const && x.ty == y.ty && x.sym == null && y.sym == null && x.imm == y.imm && x.imm2 == y.imm2;
	}

	function constOf(v:Int):Int {
		var c = f.vals[v];
		return c.op == Const && c.ty == I32 && c.sym == null && c.imm >= 0 ? c.imm : -1;
	}

	// Whether v (an I32) is never negative: a constant, or a phi each of
	// whose operands is, or is the phi plus 1 computed only where the phi is
	// below some value (a loop's counter: below a bound, the increment
	// cannot wrap)
	function nonNeg(v:Int, cfg:Cfg<MBlock>, depth:Int):Bool {
		var x = f.vals[v];
		if (x.ty != I32 || depth > 4) return false;
		switch x.op {
			case Const:
				return x.sym == null && x.imm >= 0;
			case Phi:
				for (a in x.args) {
					if (a == v) continue;
					var y = f.vals[a];
					var one = y.op == Add && (y.a == v && isOne(y.b) || y.b == v && isOne(y.a));
					if (one ? !belowSome(v, y.block, cfg) : !nonNeg(a, cfg, depth + 1)) return false;
				}
				return true;
			case _:
				return false;
		}
	}

	inline function isOne(v:Int):Bool {
		var c = f.vals[v];
		return c.op == Const && c.sym == null && c.imm == 1;
	}

	// whether a branch dominating block b found v < y (signed) for some y:
	// a block on b's dominator path entered only by that branch's edge
	function belowSome(v:Int, b:MBlock, cfg:Cfg<MBlock>):Bool {
		var idom = cfg.idom;
		var k = cfg.index(b);
		while (k > 0) {
			var x = cfg.rpo[k];
			if (x.preds.length == 1) {
				var t = x.preds[0].term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1]) {
					var c = f.vals[t.a];
					var taken = x == t.targets[0];
					if (c.op == Cmp && !c.dead)
						switch c.imm {
							case CLt if (taken && c.a == v): return true;
							case CGe if (!taken && c.a == v): return true;
							case CGt if (taken && c.b == v): return true;
							case CLe if (!taken && c.b == v): return true;
							case _:
						}
				}
			}
			k = idom[k];
		}
		return false;
	}

	// whether a branch dominating block b found v <= s or v < s
	function atMostAt(v:Int, s:Int, b:MBlock, cfg:Cfg<MBlock>):Bool {
		var idom = cfg.idom;
		var k = cfg.index(b);
		while (k > 0) {
			var x = cfg.rpo[k];
			if (x.preds.length == 1) {
				var t = x.preds[0].term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1]) {
					var c = f.vals[t.a];
					var taken = x == t.targets[0];
					if (c.op == Cmp && !c.dead)
						switch c.imm {
							case CLe | CLt if (taken && c.a == v && c.b == s): return true;
							case CGt | CGe if (!taken && c.a == v && c.b == s): return true;
							case CGe | CGt if (taken && c.a == s && c.b == v): return true;
							case CLt | CLe if (!taken && c.a == s && c.b == v): return true;
							case _:
						}
				}
			}
			k = idom[k];
		}
		return false;
	}

	// whether a branch dominating block b found k <= v for a constant k >= 0
	function nonNegAt(v:Int, b:MBlock, cfg:Cfg<MBlock>):Bool {
		var idom = cfg.idom;
		var k = cfg.index(b);
		while (k > 0) {
			var x = cfg.rpo[k];
			if (x.preds.length == 1) {
				var t = x.preds[0].term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1]) {
					var c = f.vals[t.a];
					var taken = x == t.targets[0];
					if (c.op == Cmp && !c.dead)
						switch c.imm {
							case CGe | CGt if (taken && c.a == v && constOf(c.b) >= 0): return true;
							case CLt | CLe if (!taken && c.a == v && constOf(c.b) >= 0): return true;
							case CLe | CLt if (taken && c.b == v && constOf(c.a) >= 0): return true;
							case CGt | CGe if (!taken && c.b == v && constOf(c.a) >= 0): return true;
							case _:
						}
				}
			}
			k = idom[k];
		}
		return false;
	}

	// whether a branch dominating block b found v above some value: v > y,
	// or v >= k for a constant k >= 0 (a counter's decrement there cannot
	// wrap)
	function aboveSome(v:Int, b:MBlock, cfg:Cfg<MBlock>):Bool {
		var idom = cfg.idom;
		var k = cfg.index(b);
		while (k > 0) {
			var x = cfg.rpo[k];
			if (x.preds.length == 1) {
				var t = x.preds[0].term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1]) {
					var c = f.vals[t.a];
					var taken = x == t.targets[0];
					if (c.op == Cmp && !c.dead)
						switch c.imm {
							case CGt if (taken && c.a == v): return true;
							case CLe if (!taken && c.a == v): return true;
							case CLt if (taken && c.b == v): return true;
							case CGe if (!taken && c.b == v): return true;
							case CGe if (taken && c.a == v && constOf(c.b) >= 0): return true;
							case CLt if (!taken && c.a == v && constOf(c.b) >= 0): return true;
							case CLe if (taken && c.b == v && constOf(c.a) >= 0): return true;
							case CGt if (!taken && c.b == v && constOf(c.a) >= 0): return true;
							case _:
						}
				}
			}
			k = idom[k];
		}
		return false;
	}

	inline function isConst(v:Int, k:Int):Bool {
		var c = f.vals[v];
		return c.op == Const && c.ty == I32 && c.sym == null && c.imm == k;
	}

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
		// (a join's phi and the switch on it in the block it jumps to: one block)
		mergeBlocks();
		// (the blocks that may be threaded: a phi first, a branch last)
		var any = false;
		for (b in f.blocks) {
			var n = b.ins.length;
			if (n >= 2 && n <= 4 && b.ins[0].op == Phi && (b.ins[n - 1].op == Br || n <= 3 && b.ins[n - 1].op == Switch)) {
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
		var uses = [for (_ in 0...f.vals.length) 0]; // (grows: the comparisons made below)
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
			// (a switch on a phi, or on its copy: a constant operand's edge to
			// its case, as TypeView.of's of null)
			if (n <= 3 && phi.op == Phi && br.op == Switch && uses[phi.id] == 1
				&& (n == 2 && br.a == phi.id || n == 3 && ins[1].op == Copy && ins[1].a == phi.id && br.a == ins[1].id && uses[ins[1].id] == 1)) {
				var k = 0;
				while (k < b.preds.length) {
					var p = b.preds[k], x = vals[phi.args[k]];
					var to = br.targets[br.targets.length - 1];
					if (x.op == Const && x.sym == null && x.ty == I32)
						for (q in 0...br.cases.length)
							if (br.cases[q] == x.imm) {
								to = br.targets[q];
								break;
							}
					if (x.op != Const || x.sym != null || x.ty != I32 || to == b || hasPhi(to) && to.preds.indexOf(p) >= 0) {
						k++;
						continue;
					}
					var j = to.preds.indexOf(b);
					for (i in to.ins)
						if (i.op == Phi) {
							i.addArg(i.args[j]);
							uses[i.args[j]]++;
						}
					retarget(p, b, to);
					b.preds.splice(k, 1);
					phi.removeArg(k);
					uses[x.id]--;
					threaded = true;
				}
				continue;
			}
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
					// branch on the value here (a branch tests 32 bits: a wider
					// value compared with zero first, as a tagged Null<Int> whose
					// low half is 0)
					addArgs(onSet);
					addArgs(onZero);
					var cv = v;
					if (x.ty != I32) {
						var z = new MIns(Const, x.ty);
						z.id = vals.length;
						vals.push(z);
						z.block = p;
						var c = new MIns(Cmp, I32);
						c.id = vals.length;
						vals.push(c);
						c.imm = CNe;
						c.a = v;
						c.b = z.id;
						c.block = p;
						p.ins.insert(p.ins.length - 1, z);
						p.ins.insert(p.ins.length - 1, c);
						uses.push(1);
						uses.push(1);
						cv = c.id;
					}
					t.op = Br;
					t.a = cv;
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
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Rotr | Neg | Not | FAdd | FSub | FMul | FDiv | FNeg | FSqrt | FAbs | Cmp | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits | Select | VOp | VConst:
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
		return i.b >= 0 ? i.mem : i.mem == MField ? fieldClass(i) : i.mem == MFrame ? frameClass(i) : i.mem == MGlobal
			&& f.vals[res(i.a)].op == SymAddr ? MScalar : i.mem;

	// whether an address may lie at a symbol: one of its operands, through
	// arithmetic, copies, extensions and merges, is a symbol's address
	// (Mem.sym, the one way raw memory reaches a scalar global)
	function atSymbol(v:Int, depth:Int):Bool {
		if (v < 0) return false;
		if (depth > 8) return true;
		var x = f.vals[res(v)];
		return switch x.op {
			case SymAddr: true;
			case Copy | SExt | ZExt | Trunc: atSymbol(x.a, depth + 1);
			case Add | Sub | And | Or | Xor | Select: atSymbol(x.a, depth + 1) || atSymbol(x.b, depth + 1) || atSymbol(x.c, depth + 1);
			case Phi:
				var any = false;
				for (a in x.args)
					if (!any && atSymbol(a, depth + 1)) any = true;
				any;
			case _: false;
		};
	}

	// the classes an instruction writes, as a bit set (0: none)
	function killMask(i:MIns):Int {
		if (i.isObj()) return objKill(i);
		return switch i.op {
			case Store:
				switch i.mem {
					case MInit: 0;
					// Raw memory (hxmc.unsafe.Mem) may be any memory but a
					// scalar global's: that is reached only through its
					// symbol, so a store at an address made from a symbol's
					// in this function (Mem.sym) may write one, and no other
					// does. A pointer read from memory or a static, passed
					// in, or returned by a call is taken never to address a
					// scalar static (it is malloc'ed or mapped memory, an
					// object, the stack, the runtime's data or a @:hxmc.bss
					// block): a static's value is reused across such stores,
					// and leaves loops of them (Store.base + an offset, the
					// raw memory of packages)
					case MOther:
						EVERY & ~(1 << MConst) & ~(1 << MCallOnly) & ~TLS_BITS & (atSymbol(i.a, 0) || atSymbol(i.b, 0) ? -1 : ~(1 << MScalar));
					case MField if (i.b < 0): (1 << fieldClass(i)) | (1 << MField) | (1 << MOther);
					case MField: FIELD_BITS | (1 << MField) | (1 << MOther);
					case MFrame if (i.b < 0): (1 << frameClass(i)) | (1 << MFrame) | (1 << MOther);
					case MFrame: FRAME_BITS | (1 << MFrame) | (1 << MOther);
					case _: (1 << memClass(i)) | (1 << MOther);
				}
			case TlsStore: 1 << tlsClass(i.sym);
			// (one during which nothing collects leaves the shadow-stack slots as they are)
			// (a kernel that writes no static: scalar and thread-local statics
			// as they were, FuncInfo.writesStatics)
			case Call if (i.returnsTwice || i.sym == null || !readOnly.exists(i.sym)):
				EVERY & ~(1 << MConst) & (i.keepsFrame && !i.returnsTwice ? ~((1 << MFrame) | FRAME_BITS) : -1)
					& (i.keepsStatics && !i.returnsTwice ? ~((1 << MScalar) | (1 << MTls)) : -1);
			case _: 0;
		};
	}

	// ---- object-level operations

	// every class but immutable memory (what a call may write)
	static inline var ALL = EVERY & ~(1 << MConst);

	// a field's byte offset (OInfo.loc: an Int's or Bool's is a 4-byte index; MemLower.access)
	public static inline function fieldOff(o:OInfo):Int
		return o.t.match(TRef(_) | TF64 | TI64 | TId) && !o.compact ? 8 * o.loc : 4 * o.loc;

	static inline function fieldCls(o:OInfo):Int
		return MFieldAt + ((fieldOff(o) >> 3) & 7);

	// an array element of this type is a reference (its slow path may box: a call)
	public static inline function ptrElem(t:hxmc.ir.Ir.Ty):Bool
		return !t.match(TI32 | TBool | TF64 | TI64 | TId);

	// the class an object-level read loads from (-1: not one)
	static function objLoadClass(i:MIns):Int
		return switch i.op {
			case GetField if (!i.info.t.match(TVoid)): fieldCls(i.info);
			case ArrayLength: MHdr;
			case NArrayLength: MConst;
			case NArrayGet: MElem;
			case ArrayGet if (!ptrElem(i.info.t) || i.info.prechecked): MElem;
			case _: -1;
		};

	// a field write a later read of the field may take the value of (a local's)
	static inline function objStore(i:MIns):Bool
		return (i.op == SetField || i.op == InitField) && !i.info.t.match(TVoid);

	// the class an object-level store writes (objStore)
	static inline function storeCls(i:MIns):Int
		return fieldCls(i.info);

	// the value an object-level store writes
	static inline function storedValue(i:MIns):Int
		return i.b;

	// object-level operations whose value depends on their operands alone
	static inline function objPure(op:Op):Bool
		return op == EnumTag || op == TypeTest || op == FieldAddr || op == Tag;

	// object-level operations whose lowering calls on the fast path (LICM: a call)
	static inline function objCall(op:Op):Bool
		return op == VirtualCall || op == ClosureCall || op == AnonCall || op == NewArray || op == NArrayDyn || op == Box || op == Unbox;

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
			case ArrayGet: i.info.flag ? 1 : 0;
			case NArrayGet: i.info.n;
			case TypeTest: i.info.cls.tindex;
			case FieldAddr: i.info.loc;
			case _: 0;
		};

	// the classes an object-level operation writes
	function objKill(i:MIns):Int
		return switch i.op {
			case NullCheck | GetField | FieldAddr | EnumTag | TypeTest | ArrayLength | NArrayLength | NArrayGet | InitField | Tag: 0;
			case Untag if (!i.info.t.match(TRef(_))): 0;
			case ArrayGet: ptrElem(i.info.t) && !i.info.prechecked ? ALL : 0;
			case SetField: i.info.t.match(TVoid) ? 0 : (1 << fieldCls(i.info)) | (1 << MField) | (1 << MOther);
			case AnonStore: FIELD_BITS | (1 << MField) | (1 << MOther);
			case NArraySet | ArrayInit | NArrayInit: (1 << MElem) | (1 << MOther);
			case RefStore: EVERY & ~(1 << MConst) & ~(1 << MCallOnly) & ~TLS_BITS;
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
	static inline var SWITCH_IN = -3; // (condProp: fa is one of the cases sets[fb])

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
	// (Gc.allocNow: a quarter of it at most; it is 16 KB at least)
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
		// (blocks it empties are merged as it goes)
		o.ifConvert();
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
		o.indexed();
		o.dce();
	}

	// an access at x + y, of no index: at base x, index y (as Mem's raw
	// accesses make it, which the back ends encode in the access; a span's
	// element at a sub's start, hxmc.rt.Bytes' accessors)
	function indexed() {
		for (b in f.blocks)
			for (i in b.ins)
				if ((i.op == Load || i.op == Store) && !i.dead && i.b < 0 && i.sym == null) {
					var x = f.vals[i.a];
					if (x.op != Add || x.ty != I64 || x.dead) continue;
					var l = f.vals[x.a], r = f.vals[x.b];
					if (l.op == Const || r.op == Const || l.ty != I64 || r.ty != I64) continue;
					i.a = x.a;
					i.b = x.b;
					i.imm2 = 1;
				}
	}

	// ---- if-conversion

	// whether i may run whether or not its branch is taken: it cannot fault,
	// has no effect and is cheap (integer operations; no division, load or
	// call)
	static function speculable(i:MIns):Bool
		return switch i.op {
			case Const | Copy | Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Rotr | Neg | Not | Cmp | SExt | ZExt | Trunc | Select:
				i.ty == I32 || i.ty == I64;
			case _: false;
		}

	// A branch to two short arms (or one arm and the join) that meet in a
	// join of only those two edges, whose phis are integers, becomes the arms'
	// code and a Select per phi (cmov, csel, wasm's select): `v < 0 ? 0 : v >
	// 255 ? 255 : v` costs no misprediction on data the branch predictor cannot
	// learn (pixels). An arm holds at most 5 instructions besides its jump;
	// joins are converted innermost first (rounds), and the head then jumps
	// to the join, which mergeBlocks absorbs. Returns whether anything changed.
	function ifConvert():Bool {
		var changed = false, round = true, rounds = 0;
		function arm(x:MBlock, h:MBlock, j:MBlock):Bool {
			if (x == j) return true;
			if (x.preds.length != 1 || x.preds[0] != h || x.handler || x.cold != h.cold || x.ins.length > 6) return false;
			var t = x.term();
			if (t == null || t.op != Jmp || t.targets[0] != j) return false;
			for (k in 0...x.ins.length - 1)
				if (!speculable(x.ins[k])) return false;
			return true;
		}
		while (round && rounds++ < 8) {
			round = false;
			for (h in f.blocks) {
				var br = h.term();
				if (br == null || br.op != Br || h.handler || contOf(h) != null || f.vals[br.a].ty != I32) continue;
				var t = br.targets[0], e = br.targets[1];
				if (t == e) continue;
				// the join: where both arms (or one arm and the branch) go
				var j:Null<MBlock> = null;
				function after(x:MBlock):Null<MBlock> {
					var xt = x.term();
					return xt != null && xt.op == Jmp && x.preds.length == 1 ? xt.targets[0] : null;
				}
				if (after(t) != null && after(t) == after(e)) j = after(t);
				else if (after(t) == e) j = e;
				else if (after(e) == t) j = t;
				if (j == null || j == h || j.preds.length != 2 || j.handler || !arm(t, h, j) || !arm(e, h, j)) continue;
				// the phis' operands by edge: from the then side and the else side
				var kt = j.preds.indexOf(t == j ? h : t), ke = j.preds.indexOf(e == j ? h : e);
				if (kt < 0 || ke < 0 || kt == ke) continue;
				var phis = [], ok = true;
				for (i in j.ins)
					if (i.op == Phi) {
						if (i.ty != I32 && i.ty != I64) ok = false;
						phis.push(i);
					}
				if (!ok || phis.length == 0 || phis.length > 4) continue;
				// the arms' code moves before the branch, the phis after it as selects
				br.op = Jmp;
				var cond = br.a;
				br.a = -1;
				br.targets = vector(j);
				h.ins.pop();
				for (x in [t, e])
					if (x != j) {
						for (k in 0...x.ins.length - 1) {
							var i = x.ins[k];
							i.block = h;
							h.ins.push(i);
						}
						x.ins = [];
						x.preds = [];
						x.succs = [];
					}
				for (p in phis) {
					var vt = p.args[kt], ve = p.args[ke];
					j.ins.remove(p);
					p.op = Select;
					p.a = cond;
					p.b = vt;
					p.c = ve;
					p.args = vector();
					p.block = h;
					h.ins.push(p);
				}
				h.ins.push(br);
				h.succs = [j];
				j.preds = [h];
				changed = round = true;
			}
			if (round) {
				var live = [for (b in f.blocks) if (b == f.entry || b.preds.length > 0) b];
				f.blocks = live;
				f.edited();
				mergeBlocks();
			}
		}
		return changed;
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
			&& (x.op != TypeTest || x.info.cls == y.info.cls)
			&& ver[x.id] == ver[y.id] : x.op == y.op && x.ty == y.ty && cres(x.a) == cres(y.a) && cres(x.b) == cres(y.b) && cres(x.c) == cres(y.c) && x.imm == y.imm && x.imm2 == y.imm2
			&& x.size == y.size && x.signed == y.signed && x.sym == y.sym && x.mem == y.mem && ver[x.id] == ver[y.id] && sameCases(x, y);

	// (a vector constant's words, a shuffle's lanes)
	static function sameCases(x:MIns, y:MIns):Bool {
		if (x.op != VOp && x.op != VConst) return true;
		if (x.cases.length != y.cases.length) return false;
		for (k in 0...x.cases.length)
			if (x.cases[k] != y.cases[k]) return false;
		return true;
	}

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
	// the whole value (no truncation: a vector's 16 bytes, not the low 8 or
	// 4 of v128.store64_lane, whose v128.load64_zero reads zeros above
	// them), and not the initialization of a new object (whose stores leave
	// the versions as they are: forwardStores)
	inline function forwards(st:MIns):Bool {
		var t = f.vals[res(st.c)].ty;
		return st.mem != MInit && st.size == (t == I32 ? 4 : t == V128 ? 16 : 8) && t != Void;
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
		return l.op == GetField && cres(st.a) == cres(l.a) && fieldOff(st.info) == fieldOff(l.info) && ver[st.id] == ver[l.id] && f.vals[res(st.b)].ty == l.ty;

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
						var h = op == Store ? hashOf(Load, i.a, i.b, -1, i.imm, i.imm2, ver[i.id]) : hashOf(GetField, i.a, -1, -1, fieldOff(i.info), 0, ver[i.id]);
						h = (h ^ (h >>> 15)) * 0x2c1b3c6d;
						var bk = (h ^ (h >>> 12)) & mask;
						chain[i.id] = head[bk];
						head[bk] = i.id;
						log.push(i.id);
						log.push(bk);
						continue;
					}
					// (a type parameter's word decoded as the number it encodes: that
					// number, as a field a Sroa'd object or an inlined generic
					// function stored and read back)
					if (op == Untag) {
						var w = vals[res(i.a)];
						if (w.op == Tag && !w.dead && w.info.t == i.info.t) {
							repl[i.id] = res(w.a);
							i.dead = true;
							continue;
						}
					}
					// (comparisons are recomputed: they fuse with their branch;
					// those of constants are folded)
					if (op == Cmp) {
						if (fold(i)) cmpFolded = true;
						continue;
					}
					// (a division may trap: not pure, but of constants folded)
					if ((op == UDiv || op == URem) && fold(i)) continue;
					if (!(pure(op) || op == Load || op == TlsLoad || objPure(op) || objLoadClass(i) >= 0)) continue;
					// (a vector constant folded is still numbered: one for its copies)
					if (fold(i) && i.op != VConst) continue;
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
						} else if (y.op == SetField || y.op == InitField) {
							if (op == GetField && answersObj(y, i)) {
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
			// (a span reinterpreted: its length times one size over the other;
			// of words below 2^31 or 2^63, where unsigned is signed)
			case UDiv | URem if (plain(x) && plain(y) && x.ty == i.ty && y.ty == i.ty):
				var a = i.ty == I64 ? haxe.Int64.make(x.imm2, x.imm) : haxe.Int64.ofInt(x.imm);
				var b = i.ty == I64 ? haxe.Int64.make(y.imm2, y.imm) : haxe.Int64.ofInt(y.imm);
				if (a < 0 || b <= 0) return false;
				var r = i.op == UDiv ? a / b : a % b;
				return set(r.low, i.ty == I64 ? r.high : 0);
			case Cmp if (plain(x) && plain(y) && x.ty == y.ty && i.imm < (FEq : Int)):
				// (signed and unsigned order of two words, 32 or 64 bits)
				var a = x.ty == I64 ? haxe.Int64.make(x.imm2, x.imm) : haxe.Int64.ofInt(x.imm);
				var b = x.ty == I64 ? haxe.Int64.make(y.imm2, y.imm) : haxe.Int64.ofInt(y.imm);
				var s = haxe.Int64.compare(a, b);
				var u = x.ty == I64 ? haxe.Int64.ucompare(a, b) : haxe.Int64.ucompare(haxe.Int64.make(0, x.imm), haxe.Int64.make(0, y.imm));
				var t = switch (i.imm : Cond) {
					case CEq: s == 0;
					case CNe: s != 0;
					case CLt: s < 0;
					case CLe: s <= 0;
					case CGt: s > 0;
					case CGe: s >= 0;
					case CULt: u < 0;
					case CULe: u <= 0;
					case CUGt: u > 0;
					case _: u >= 0;
				};
				return set(t ? 1 : 0, 0);
			// (a splat of a constant: a vector constant, which the back ends
			// load or fold into its users instead of keeping it in a register)
			case VOp if (plain(x) && i.imm >= 0x0f && i.imm <= 0x12):
				var lo = x.imm, hi = i.imm == 0x12 ? x.imm2 : x.imm;
				switch i.imm {
					case 0x0f:
						lo &= 0xff;
						lo |= lo << 8;
						lo |= lo << 16;
						hi = lo;
					case 0x10:
						lo = (lo & 0xffff) | (lo << 16);
						hi = lo;
					case _:
				}
				i.op = VConst;
				i.cases = haxe.ds.Vector.fromArrayCopy([lo, hi, lo, hi]);
				i.imm = i.imm2 = 0;
				i.a = i.b = i.c = -1;
				return true;
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
		return pure(i.op) || objPure(i.op) || objLoadClass(i) >= 0 || i.op == ArrayGet || i.op == Load || i.op == TlsLoad || i.op == Const || i.op == ConstF || i.op == SymAddr || i.op == StackAddr || i.op == Copy || i.op == Phi;
}
