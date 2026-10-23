package hxmc;

import hxmc.Mir;
import core.ds.VectorTools.vector;

// Allocation folding: an allocation of the nursery of a constant size
// (MemLower.alloc's shape) that follows another one with nothing between them
// that could collect or allocate becomes part of it: one test of the room
// left and one bump for both, the second's header written where the first's
// object ends (the two are objects of their own from there: the collector
// copies them apart). The first's slow path allocates both, its header
// written again after the call (the runtime makes a record of the size it is
// given); the second's slow path, its spills and reloads, are gone: its
// object is the first's address plus the first's bytes. Runs after MemLower
// (Escape's replacements are not folded; Opt.lowered cleans up after it).
class Fold {
	// the most bytes one allocation takes for the objects folded into it
	static inline var MAX_BYTES = 4096;

	public static var on = Sys.getEnv("HXMC_FOLD") != "0";
	// (HXMC_FOLD_WHY=1: what stops each allocation's chain, counted: Driver's stats)
	public static var whyOn = Sys.getEnv("HXMC_FOLD_WHY") == "1";

	public var why = new Map<String, Int>();

	function count(k:String)
		why.set(k, (why.exists(k) ? why.get(k) : 0) + 1);

	var f:MFunc;
	var vals:Array<MIns>;

	public var folded = 0; // allocations made part of another

	public function new(f:MFunc) {
		this.f = f;
		vals = f.vals;
	}

	public function run() {
		f.edited();
		var i = 0;
		while (i < f.blocks.length) {
			var b = f.blocks[i];
			var s = site(b);
			if (s != null) chain(s);
			else if (whyOn && dynHead(b) != null) count("run-time size first: " + whyNot(dynHead(b)));
			i++;
		}
		if (folded > 0) f.blocks = [for (b in f.blocks) if (!removed.exists(b.id)) b];
	}

	var removed = new Map<Int, Bool>();

	// the allocations folded into s, as long as the next one follows on a
	// straight line
	function chain(s:Site) {
		while (true) {
			var next = following(s);
			if (next == null || s.total + next.bytes > MAX_BYTES) {
				if (whyOn) count("constant first: " + (next != null ? "too big" : whyNot(s.join)));
				return;
			}
			fold(s, next);
		}
	}

	// (diagnostics) the join of an allocation of a size known at run time headed by b, or null
	function dynHead(b:MBlock):Null<MBlock> {
		var br = b.term();
		if (br == null || br.op != Br || b.succs.length != 2) return null;
		var cmp = vals[br.a];
		if (cmp.op != Cmp || cmp.imm != (CGe : Int) || vals[cmp.b].op == Const) return null;
		var sub = vals[cmp.a];
		if (sub.op != Sub || vals[sub.b].op != TlsLoad || vals[sub.b].sym != "rt_young_ptr") return null;
		var fast = br.targets[0];
		return fast.succs.length == 1 ? fast.succs[0] : null;
	}

	// (diagnostics) what stops the next allocation after the join from folding:
	// the first thing on the way
	function whyNot(join:MBlock):String {
		var b = join;
		var seen = 0;
		while (seen++ < 64) {
			for (i in b.ins) {
				if (i.dead || i.op == Phi) continue;
				switch i.op {
					case TlsLoad if (i.sym == "rt_young_ptr"):
						return dynHead(b) != null ? "a run-time size next" : site(b) != null ? "a constant next (?)" : "the pointer read";
					case Call:
						return i.keepsFrame ? "a call that cannot collect (" + i.sym + ")" : "a call";
					case Ret | Unreachable:
						return "the end";
					case _:
				}
			}
			var t = b.term();
			if (t == null) return "the end";
			if (t.op != Jmp) return allocAhead(b) ? "an allocation after a branch" : "a branch, no allocation after";
			b = b.succs[0];
			if (b.preds.length != 1) return allocAhead(b) ? "an allocation after a merge" : "a merge, no allocation after";
			if (b.cold) return "a cold block";
		}
		return "too far";
	}

	// (diagnostics) whether an allocation comes from b on some way before a call
	function allocAhead(b:MBlock):Bool {
		var seen = new Map<Int, Bool>(), todo = [b], n = 0;
		while (todo.length > 0 && n++ < 64) {
			var x = todo.pop();
			if (seen.exists(x.id) || x.cold) continue;
			seen.set(x.id, true);
			var stop = false;
			for (i in x.ins) {
				if (i.dead) continue;
				if (i.op == TlsLoad && i.sym == "rt_young_ptr") return true;
				if (i.op == Call || i.op == Ret || i.op == Unreachable) {
					stop = true;
					break;
				}
			}
			if (!stop)
				for (y in x.succs)
					todo.push(y);
		}
		return false;
	}

	// the allocation that follows s's on a straight line (each block the only
	// successor of the one before and the only predecessor of the next), with
	// nothing on the way that may collect or allocate
	function following(s:Site):Null<Site> {
		var b = s.join;
		var seen = 0;
		while (seen++ < 64) {
			var n = site(b);
			var stop = n != null ? n.ptr : null;
			for (i in b.ins) {
				if (i.dead || i.op == Phi) continue;
				if (i == stop) return n;
				if (!harmless(i)) return null;
			}
			var t = b.term();
			if (t == null || t.op != Jmp || b.succs.length != 1) return null;
			b = b.succs[0];
			if (b.preds.length != 1 || b.cold || removed.exists(b.id)) return null;
		}
		return null;
	}

	// an instruction that neither collects nor moves the nursery's pointer
	function harmless(i:MIns):Bool
		return switch i.op {
			case Call | Ret | Unreachable | Switch | Br: false;
			case TlsLoad | TlsStore: !StringTools.startsWith(i.sym, "rt_young_");
			case _: true;
		}

	// MemLower.alloc's shape (a constant size): head: ptr = rt_young_ptr,
	// lim = rt_young_(r)limit, br (lim - ptr >= bytes) fast, slow; fast:
	// rt_young_ptr = ptr + bytes, the header's two words at ptr, o = ptr +
	// 8, jmp join; slow (cold): an allocation stub's call (spills and reloads
	// around it), on to join; join: phi(o, the call), and those of what the
	// slow path reloaded
	function site(head:MBlock):Null<Site> {
		var br = head.term();
		if (br == null || br.op != Br || head.succs.length != 2) return null;
		var cmp = vals[br.a];
		if (cmp.op != Cmp || cmp.dead || cmp.imm != (CGe : Int)) return null;
		var sub = vals[cmp.a], bytes = vals[cmp.b];
		if (sub.op != Sub || bytes.op != Const || bytes.sym != null) return null;
		var lim = vals[sub.a], ptr = vals[sub.b];
		if (ptr.op != TlsLoad || ptr.sym != "rt_young_ptr" || ptr.block != head) return null;
		if (lim.op != TlsLoad || lim.block != head || (lim.sym != "rt_young_limit" && lim.sym != "rt_young_rlimit")) return null;
		var fast = br.targets[0], slow = br.targets[1];
		if (fast == slow || fast.preds.length != 1 || fast.succs.length != 1 || !slow.cold || slow.preds.length != 1) return null;
		var join = fast.succs[0];
		var s = new Site();
		s.head = head;
		s.fast = fast;
		s.join = join;
		s.ptr = ptr;
		s.lim = lim;
		s.cmp = cmp;
		s.bytes = s.total = bytes.imm;
		if (s.bytes < 16 || s.bytes & 7 != 0) return null;
		for (i in fast.ins) {
			if (i.dead) continue;
			switch i.op {
				case Const | Jmp:
				case Add if (i.a == ptr.id && isConst(i.b, 8) && s.o == null):
					s.o = i;
				case Add if (i.a == ptr.id && isConst(i.b, s.bytes) && s.bump == null):
					s.bump = i;
				case TlsStore if (i.sym == "rt_young_ptr" && s.tls == null):
					s.tls = i;
				case Store if (i.a == ptr.id && i.b < 0 && i.size == 4 && i.imm == 0 && s.ty == null):
					s.ty = i;
				case Store if (i.a == ptr.id && i.b < 0 && i.size == 4 && i.imm == 4 && s.hdr == null):
					s.hdr = i;
				case _:
					return null;
			}
		}
		if (s.o == null || s.bump == null || s.tls == null || s.tls.a != s.bump.id || s.ty == null || s.hdr == null) return null;
		// the slow path: the blocks from slow to join, entered only from head
		var region = [slow], k = 0;
		var inRegion = new Map<Int, Bool>();
		inRegion.set(slow.id, true);
		var last:Null<MBlock> = null;
		while (k < region.length) {
			var b = region[k++];
			if (region.length > 16) return null;
			for (p in b.preds)
				if (p != head && !inRegion.exists(p.id)) return null;
			for (x in b.succs) {
				if (x == join) {
					if (last != null && last != b) return null;
					last = b;
				} else if (!inRegion.exists(x.id)) {
					if (x == fast || x == head) return null;
					inRegion.set(x.id, true);
					region.push(x);
				}
			}
			for (i in b.ins)
				if (!i.dead && i.op == Call) {
					if (s.call != null || i.sym == null || !StringTools.startsWith(i.sym, MemLower.ALLOC_STUB)) return null;
					s.call = i;
				}
		}
		if (last == null || s.call == null || join.preds.length != 2) return null;
		s.region = region;
		s.last = last;
		var fi = join.preds.indexOf(fast), si = join.preds.indexOf(last);
		if (fi < 0 || si < 0 || fi == si) return null;
		s.fastIdx = fi;
		for (i in join.ins) {
			if (i.dead || i.op != Phi) continue;
			if (i.args[fi] == s.o.id) {
				if (s.result != null || i.args[si] != s.call.id) return null;
				s.result = i;
			}
		}
		if (s.result == null) return null;
		return s;
	}

	function isConst(v:Int, k:Int):Bool {
		var c = vals[v];
		while (c.op == Copy)
			c = vals[c.a];
		return c.op == Const && c.sym == null && c.imm == k && c.imm2 == (k < 0 ? -1 : 0);
	}

	// s2 made part of s (which follows it: s.join reaches s2.head on a straight line)
	function fold(s:Site, s2:Site) {
		var off = s.total;
		s.total += s2.bytes;
		// one test and one bump for both
		var c = lconst(s.head, s.cmp, s.total);
		s.cmp.b = c.id;
		var b = lconst(s.fast, s.bump, s.total);
		s.bump.b = b.id;
		if (s2.lim.sym == "rt_young_limit" && s.lim.sym != "rt_young_limit") {
			// (the second's must read as zeros: the first's test is the zeroing one)
			var l = ins(TlsLoad, I64, s.head, s.lim);
			l.sym = "rt_young_limit";
			vals[s.cmp.a].a = l.id;
			s.lim = l;
		}
		// the slow path allocates both: the stub of the new size, then the
		// first's header again (once)
		var parts = s.call.sym.split("$");
		parts[parts.length - 1] = Std.string(s.total);
		s.call.sym = parts.join("$");
		if (!s.rewritten) {
			s.rewritten = true;
			var cb = s.call.block;
			var at = cb.ins.indexOf(s.call) + 1;
			for (st in [s.ty, s.hdr]) {
				var v = clone(vals[st.c], cb, at++);
				var w = new MIns(Store, Void);
				w.mem = Opt.MInit;
				w.a = s.call.id;
				w.c = v.id;
				w.imm = st.imm - 8;
				w.imm2 = 1;
				w.size = 4;
				put(w, cb, at++);
			}
		}
		// the second: the first's address plus what it had, its header written
		var h = s2.head;
		for (i in [s2.ptr, s2.lim, vals[s2.cmp.a], s2.cmp, vals[s2.cmp.b], h.term()])
			if (i.block == h) kill(i);
		var o2off = lconst(h, null, off);
		var o2 = ins(Add, I64, h, null);
		o2.a = s.result.id;
		o2.b = o2off.id;
		for (st in [s2.ty, s2.hdr]) {
			var v = clone(vals[st.c], h, h.ins.length);
			var w = new MIns(Store, Void);
			w.mem = Opt.MInit;
			w.a = o2.id;
			w.c = v.id;
			w.imm = st.imm - 8;
			w.imm2 = 1;
			w.size = 4;
			put(w, h, h.ins.length);
		}
		var j = new MIns(Jmp, Void);
		j.targets = vector(s2.join);
		put(j, h, h.ins.length);
		// its join: reached from h only, its phis the values the fast path had
		var join = s2.join;
		for (i in join.ins) {
			if (i.dead || i.op != Phi) continue;
			var v = i.args[s2.fastIdx];
			i.op = Copy;
			i.a = v == s2.o.id ? o2.id : v;
			i.args = vector();
		}
		join.preds = [h];
		h.succs = [join];
		for (x in [s2.fast].concat(s2.region)) {
			removed.set(x.id, true);
			for (i in x.ins)
				kill(i);
		}
		folded++;
	}

	function kill(i:MIns) {
		i.dead = true;
		if (i.block != null) i.block.ins.remove(i);
	}

	// a new instruction, put before `before` (the block's terminator when null)
	function ins(op:Op, ty:MTy, b:MBlock, before:Null<MIns>):MIns {
		var i = new MIns(op, ty);
		var at = before == null ? (b.term() == null ? b.ins.length : b.ins.length - 1) : b.ins.indexOf(before);
		put(i, b, at);
		return i;
	}

	function put(i:MIns, b:MBlock, at:Int) {
		i.id = vals.length;
		vals.push(i);
		i.block = b;
		b.ins.insert(at, i);
	}

	function lconst(b:MBlock, before:Null<MIns>, v:Int):MIns {
		var c = ins(Const, I64, b, before);
		c.imm = v;
		return c;
	}

	// a copy of the constant c at b's position at
	function clone(c:MIns, b:MBlock, at:Int):MIns {
		while (c.op == Copy)
			c = vals[c.a];
		if (c.op != Const) throw "hxmc: Fold: a header word that is not a constant";
		var i = new MIns(Const, c.ty);
		i.imm = c.imm;
		i.imm2 = c.imm2;
		i.sym = c.sym;
		put(i, b, at);
		return i;
	}
}

private class Site {
	public var head:MBlock;
	public var fast:MBlock;
	public var join:MBlock;
	public var region:Array<MBlock>; // the slow path's blocks
	public var last:MBlock; // the slow path's block into join
	public var fastIdx = 0; // join's predecessor index of fast
	public var ptr:MIns; // rt_young_ptr
	public var lim:MIns; // the limit tested
	public var cmp:MIns; // (lim - ptr) >= bytes
	public var bytes = 0; // its own
	public var total = 0; // with those folded into it
	public var o:MIns; // ptr + 8
	public var bump:MIns; // ptr + bytes
	public var tls:MIns; // rt_young_ptr = bump
	public var ty:MIns; // the header's stores: its first word (type index), its second
	public var hdr:MIns;
	public var call:MIns; // the stub's
	public var result:MIns; // join's phi(o, the call)
	public var rewritten = false; // the slow path writes the header again

	public function new() {}
}
