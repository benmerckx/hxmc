package hxmc;

import haxe.ds.Vector;
import hxmc.Mir;

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
class Opt {
	// memory classes (MIns.mem)
	public static inline var MOther = 0; // anything: written by any store or call
	public static inline var MHdr = 1; // array headers (length, kind, data)
	public static inline var MElem = 2; // array elements
	public static inline var MField = 3; // object fields
	public static inline var MGlobal = 4; // global variables
	public static inline var MCallOnly = 5; // changed only by calls (rt_globals, the nursery bounds, inline caches)
	public static inline var MFrame = 6; // shadow-stack slots (calls may move what they hold)
	public static inline var MConst = 7; // never written (type tables, string lengths, object type indices)
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
	static inline var NCLS = 30;
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
		simplifyCfg();
		var order = rpo();
		if (order.length == 0) return;
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
			versions(order);
			canonicalize();
			gvn(order);
			forwardStores();
		}
		rewrite();
		dce();
		if (condProp()) {
			pruneBlocks();
			mergeBlocks();
			dce();
		}
		if (licmOn)
			for (_ in 0...3)
				if (!licm()) break;
	}

	static var licmOn = Sys.getEnv("HXMC_LICM") != "0";

	// ---- loop-invariant code motion

	// A load that cannot fault wherever it moves: of a global variable (the
	// globals table, or a scalar global's own symbol), of immutable memory
	// at a symbol, of runtime state at a symbol, or of a thread-local variable.
	// Runtime state can move only when the loop's calls invalidate it.
	static inline function safeLoad(i:MIns, vals:Array<MIns>):Bool
		return i.op == TlsLoad || i.op == Load && (i.mem == MGlobal || (i.mem == MConst || i.mem == MCallOnly) && i.b < 0 && vals[i.a].op == SymAddr);

	// One round, over the loops that hold no loop moved from in this round
	// (the caller repeats: what left an inner loop may then leave its outer
	// one). A loop needs a single predecessor from outside (its edge is
	// split when that block has other successors); what moves keeps its
	// order at the end of that block. Returns whether anything moved.
	function licm():Bool {
		var order = rpo();
		var n = order.length;
		if (n < 2) return false;
		var dom = dominators(order);
		var idom = dom.idom;
		var inOrder = order[0].mark; // (set by dominators: tmp is the reverse postorder index)
		var vals = f.vals;
		var body:Array<Bool> = [];
		var inv:Array<Bool> = [];
		var moved = false;
		var nextBlock = 0;
		for (b in f.blocks)
			if (b.id >= nextBlock) nextBlock = b.id + 1;
		var k = n;
		while (k-- > 1) { // inner loops first: their headers come later
			var h = order[k];
			if (h.handler) continue;
			var latches = [];
			for (p in h.preds)
				if (p.mark == inOrder && p.tmp >= k) {
					var x = p.tmp;
					while (x > k)
						x = idom[x];
					if (x == k) latches.push(p);
				}
			if (latches.length == 0) continue;
			// the loop: the blocks reaching a latch without passing the header
			body.resize(0);
			body.resize(n);
			body[k] = true;
			var members = [h];
			var stack = [];
			var ok = true;
			for (l in latches)
				if (!body[l.tmp]) {
					body[l.tmp] = true;
					members.push(l);
					stack.push(l);
				}
			while (stack.length > 0 && ok) {
				var b = stack.pop();
				for (p in b.preds) {
					if (p.mark != inOrder) {
						ok = false; // a block made this round (a loop inside already moved from)
						break;
					}
					if (!body[p.tmp]) {
						body[p.tmp] = true;
						members.push(p);
						stack.push(p);
					}
				}
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
						if (i.op == Call && !b.cold) calls = true;
					}
			if (calls) continue;
			// the movable instructions, in reverse postorder of their blocks
			members.sort((x, y) -> x.tmp - y.tmp);
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
						case Load | TlsLoad:
							safeLoad(i, vals) && kills & (1 << (i.op == TlsLoad ? tlsClass(i.sym) : i.mem)) == 0;
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
				if (count != 1 || t.op == Switch) continue;
				pre = new MBlock(nextBlock++);
				pre.cold = h.cold && outside.cold;
				pre.sealed = pre.filled = true;
				var j = new MIns(Jmp, Void);
				j.id = vals.length;
				vals.push(j);
				j.block = pre;
				j.targets = [h];
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
		return moved;
	}

	// ---- conditions known from dominating branches

	// A branch on a comparison already decided on the way (a block reached
	// only through one edge of a branch on the same comparison, or on its
	// negation, dominates it) is a jump: the repeated tests of an array's
	// element kind, of a value against null. Returns whether a branch changed.
	function condProp():Bool {
		var order = rpo();
		var n = order.length;
		if (n < 3) return false;
		var dom = dominators(order);
		var childHead = dom.childHead, childNext = dom.childNext;
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
						}
					}
				}
				var t = b.term();
				if (t != null && t.op == Br && t.targets[0] != t.targets[1] && fc.length > 0) {
					var c = vals[t.a];
					if (c.op == Cmp) {
						var known = 0; // 1 true, 2 false
						var k = fc.length;
						while (k-- > 0 && known == 0) {
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
									if (i.op == Phi) i.args.splice(q, 1);
							}
							t.op = Jmp;
							t.a = -1;
							t.targets = [keep];
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
		return changed;
	}

	static inline function isEqNe(c:Int):Bool
		return c == (CEq : Int) || c == (CNe : Int);

	// immediate dominators (Cooper, Harvey and Kennedy) as reverse postorder
	// indices, and the dominator tree's children lists
	function dominators(order:Array<MBlock>):{idom:Vector<Int>, childHead:Vector<Int>, childNext:Vector<Int>} {
		var n = order.length;
		var inOrder = f.newMark();
		for (k in 0...n) {
			order[k].mark = inOrder;
			order[k].tmp = k;
		}
		var idom = MFunc.ints(n, -1);
		idom[0] = 0;
		// the predecessors in the order, by index: predIdx[predAt[k]...predAt[k + 1]]
		var predAt = new Vector<Int>(n + 1);
		var m = 0;
		for (k in 0...n) {
			predAt[k] = m;
			for (p in order[k].preds)
				if (p.mark == inOrder) m++;
		}
		predAt[n] = m;
		var predIdx = new Vector<Int>(m);
		m = 0;
		for (b in order)
			for (p in b.preds)
				if (p.mark == inOrder) predIdx[m++] = p.tmp;
		var changed = true;
		while (changed) {
			changed = false;
			for (k in 1...n) {
				var d = -1;
				for (q in predAt[k]...predAt[k + 1]) {
					var p = predIdx[q];
					if (idom[p] < 0) continue;
					if (d < 0) d = p else {
						var x = p, y = d;
						while (x != y) {
							while (x > y)
								x = idom[x];
							while (y > x)
								y = idom[y];
						}
						d = x;
					}
				}
				if (d >= 0 && idom[k] != d) {
					idom[k] = d;
					changed = true;
				}
			}
		}
		var childHead = MFunc.ints(n, -1), childNext = MFunc.ints(n, -1);
		var k = n - 1;
		while (k >= 1) {
			var d = idom[k];
			childNext[k] = childHead[d];
			childHead[d] = k;
			k--;
		}
		return {idom: idom, childHead: childHead, childNext: childNext};
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
					if (i.op == Phi) i.args.splice(k, 1);
			}
			t.op = Jmp;
			t.a = -1;
			t.targets = [keep];
			b.succs = [keep];
		}
		var uses = MFunc.ints(f.vals.length, 0);
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.a >= 0) uses[i.a]++;
				if (i.b >= 0) uses[i.b]++;
				if (i.c >= 0) uses[i.c]++;
				if (i.args != null)
					for (x in i.args)
						uses[x]++;
			}
		var vals = f.vals;
		for (b in f.blocks.copy()) {
			if (b == f.entry || b.handler) continue;
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
						i.args.push(i.args[j]);
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
					t.targets = [onSet, onZero];
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
				phi.args.splice(k, 1);
			}
		}
		pruneBlocks();
		mergeBlocks();
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
				if (s == b || s == f.entry || s.preds.length != 1 || s.handler || s.cold != b.cold) break;
				// phis of a single predecessor are their operand
				var rest = [];
				for (i in s.ins)
					if (i.op == Phi) {
						i.op = Copy;
						i.a = i.args[0];
						i.args = null;
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
			t.targets = [to];
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
						if (i.op == Phi) i.args.splice(k, 1);
					k = s.preds.indexOf(b);
				}
			}
		}
		if (!all) f.blocks = [for (b in f.blocks) if (b.mark == reach) b];
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
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Store if ((i.mem == MInit || i.mem == MField) && i.b < 0):
						var base = baseOf(i.a), d = i.imm + dispOf(i.a), sz = i.size;
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
						if (i.mem == MOther || i.mem == MField || i.mem == MInit) clear();
					case Load:
						var base = baseOf(i.a);
						var ld = i.imm + dispOf(i.a);
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

	function rpo():Array<MBlock> {
		var seen = f.newMark();
		var post = [];
		var stack:Array<MBlock> = [f.entry];
		var idx:Array<Int> = [0];
		f.entry.mark = seen;
		while (stack.length > 0) {
			var top = stack.length - 1;
			var b = stack[top];
			var k = idx[top];
			if (k < b.succs.length) {
				idx[top] = k + 1;
				var s = b.succs[k];
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
		return post;
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

	var next = 1; // the next fresh version

	// the memory versions: per block in reverse postorder, from its
	// predecessors' (a loop header: new versions of what the loop writes),
	// through its instructions; recorded per load
	function versions(order:Array<MBlock>) {
		var n = order.length;
		var inOrder = f.newMark();
		for (k in 0...n) {
			order[k].mark = inOrder;
			order[k].tmp = k;
		}
		// per block: the classes it writes
		var kill = new Vector<Int>(n);
		for (k in 0...n) {
			var m = 0;
			for (i in order[k].ins)
				if (!i.dead) m |= killMask(i);
			kill[k] = m;
		}
		var outs = new Vector<Vector<Int>>(n);
		for (k in 0...n) {
			var b = order[k];
			var v:Vector<Int> = null;
			var latch = -1;
			var mixed = 0; // classes the forward predecessors disagree on
			for (p in b.preds) {
				if (p.mark != inOrder) continue;
				var pk = p.tmp;
				if (pk >= k) {
					if (pk > latch) latch = pk;
					continue;
				}
				var o = outs[pk];
				if (v == null) v = o.copy() else
					for (c in 0...NCLS)
						if (v[c] != o[c]) mixed |= 1 << c;
			}
			if (v == null || b.handler) {
				v = new Vector<Int>(NCLS);
				for (c in 0...NCLS)
					v[c] = next++;
			} else {
				if (latch >= 0)
					for (q in k...latch + 1)
						mixed |= kill[q];
				for (c in 0...NCLS)
					if (mixed & (1 << c) != 0) v[c] = next++;
			}
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.op == Load) ver[i.id] = v[memClass(i)] else if (i.op == TlsLoad) ver[i.id] = v[tlsClass(i.sym)];
				var m = killMask(i);
				if (m != 0)
					for (c in 0...NCLS)
						if (m & (1 << c) != 0) v[c] = next++;
				// (a store: the version it leaves its memory in, that of the loads it can answer)
				if (i.op == Store) ver[i.id] = v[memClass(i)];
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
		return x.op == y.op && x.ty == y.ty && cres(x.a) == cres(y.a) && cres(x.b) == cres(y.b) && cres(x.c) == cres(y.c) && x.imm == y.imm && x.imm2 == y.imm2
			&& x.size == y.size && x.signed == y.signed && x.sym == y.sym && x.mem == y.mem && ver[x.id] == ver[y.id];

	inline function hash(i:MIns):Int
		return hashOf(i.op, i.a, i.b, i.c, i.imm, i.imm2, ver[i.id]);

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

	// value numbering in a preorder walk of the dominator tree, with a
	// scoped table (entries made in a subtree are undone after it); a store
	// is an entry too, under the key of the load of its address, which then
	// takes the stored value (store-to-load forwarding: a value kept in a
	// shadow-stack slot and read back before the next call)
	function gvn(order:Array<MBlock>) {
		var n = order.length;
		var inOrder = f.newMark();
		for (k in 0...n) {
			order[k].mark = inOrder;
			order[k].tmp = k;
		}
		// immediate dominators (Cooper, Harvey and Kennedy), as rpo indices
		var idom = MFunc.ints(n, -1);
		idom[0] = 0;
		var preds = [for (b in order) [for (p in b.preds) if (p.mark == inOrder) p.tmp]];
		var changed = true;
		while (changed) {
			changed = false;
			for (k in 1...n) {
				var d = -1;
				for (p in preds[k]) {
					if (idom[p] < 0) continue;
					if (d < 0) d = p else {
						var x = p, y = d;
						while (x != y) {
							while (x > y)
								x = idom[x];
							while (y > x)
								y = idom[y];
						}
						d = x;
					}
				}
				if (d >= 0 && idom[k] != d) {
					idom[k] = d;
					changed = true;
				}
			}
		}
		// children lists
		var childHead = MFunc.ints(n, -1), childNext = MFunc.ints(n, -1);
		var k = n - 1;
		while (k >= 1) {
			var d = idom[k];
			childNext[k] = childHead[d];
			childHead[d] = k;
			k--;
		}
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
					if (op == Store) {
						if (!forwards(i)) continue;
						var h = hashOf(Load, i.a, i.b, -1, i.imm, i.imm2, ver[i.id]);
						h = (h ^ (h >>> 15)) * 0x2c1b3c6d;
						var bk = (h ^ (h >>> 12)) & mask;
						chain[i.id] = head[bk];
						head[bk] = i.id;
						log.push(i.id);
						log.push(bk);
						continue;
					}
					// (comparisons are recomputed: they fuse with their branch)
					if (!(pure(op) || op == Load || op == TlsLoad) || op == Cmp) continue;
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
				if (i.args != null)
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
					if (i.args != null)
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
			if (i.args != null)
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
		return pure(i.op) || i.op == Load || i.op == TlsLoad || i.op == Const || i.op == ConstF || i.op == SymAddr || i.op == StackAddr || i.op == Copy;
}
