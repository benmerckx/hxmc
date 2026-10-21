package hxmc;

import hxmc.ir.Ir;
import hxmc.Lir.Bits;
import haxe.ds.Vector;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;

// Which reference locals live in shadow-stack slots (a backward liveness
// over the structured statements, from hxc's analysis for C: a reference
// live across a GC point is rooted; at a cold site the references live
// across its slow path are spilled there instead), with bit sets over local
// ids instead of maps. Rooted locals that never live at the same time share
// a slot (assign: interference at definitions, greedy coloring), except
// locals that may be read before they are set, a handler's reads of what its
// try body assigns included (their slots start as null). Also which locals those are.
class Roots {
	var n:Int;
	var refs:Bits; // locals of reference type
	public var rooted:Bits;
	public var spills = new Map<Int, Array<Local>>(); // SCold id -> references live across its slow path
	var spillSets = new Map<Int, Bits>(); // (the same, as they are found)
	var byId:haxe.ds.Vector<Null<Local>>;
	// interference of the reference locals (dense indices; null: none kept,
	// a slot per rooted local)
	var refIdx:haxe.ds.Vector<Int>;
	var inter:Null<Array<Bits>>;
	// the raw-address check (rawViolations): locals holding addresses of heap
	// objects, what is found, the GC point being looked at
	var raws:Null<Bits>;
	var rawErrors:Array<String> = [];
	var point = "";
	var brk:Array<Bits> = [];
	var cont:Array<Bits> = [];

	function new() {}

	public static function analyze(f:FuncInfo):Roots {
		var r = new Roots();
		var all = f.args.concat(f.locals);
		var n = 0;
		for (l in all)
			if (l.id >= n) n = l.id + 1;
		r.n = n;
		r.byId = new haxe.ds.Vector(n);
		r.refs = new Bits(n);
		for (l in all) {
			r.byId[l.id] = l;
			if (Ir.isRef(l.ty)) r.refs.set(l.id);
		}
		r.rooted = new Bits(n);
		r.refIdx = hxmc.Lir.Arrays.filled(n, -1);
		var nref = 0;
		for (l in all)
			if (r.refs.get(l.id)) r.refIdx[l.id] = nref++;
		if (nref <= MAX_SHARED) r.inter = [for (_ in 0...nref) new Bits(nref)];
		var liveIn = r.seq(f.body, new Bits(n));
		// the arguments are set at the entry, together
		var atEntry = liveIn.copy();
		for (a in f.args)
			if (r.refs.get(a.id)) atEntry.set(a.id);
		for (a in f.args)
			r.def(a.id, atEntry);
		// try functions: a reference assigned inside a try body lives in its
		// slot, so that a second return of setjmp finds its latest value
		if (f.hasTry)
			for (id in MirBuild.assignedInTry(f).keys())
				if (r.refs.get(id)) r.rooted.set(id);
		r.spillLists();
		return r;
	}

	// A reference live across the slow paths of many cold sites is rooted
	// instead: each slow path would store and reload it, and the reloaded
	// values meet the fast path's in a phi after it, so a value live across k
	// sites costs O(k) code, and n such values O(n * k) (ml2hx's tables:
	// nested constructor calls over a thousand values, millions of Mir values
	// and minutes of register allocation). In its slot it is stored once.
	static inline var MAX_COLD_SPILLS = 32;

	function spillLists() {
		var count = hxmc.Lir.Arrays.filled(n, 0);
		var many = false;
		for (set in spillSets)
			for (k in 0...set.w.length) {
				var x = set.w[k];
				while (x != 0) {
					var b = x & -x;
					var i = (k << 5) + bitIndex(b);
					x &= x - 1;
					if (++count[i] > MAX_COLD_SPILLS) many = true;
				}
			}
		if (many)
			for (i in 0...n)
				if (count[i] > MAX_COLD_SPILLS) rooted.set(i);
		for (id => set in spillSets) {
			var list = [];
			for (k in 0...set.w.length) {
				var x = set.w[k];
				while (x != 0) {
					var b = x & -x;
					var i = (k << 5) + bitIndex(b);
					x &= x - 1;
					if (byId[i] != null && count[i] <= MAX_COLD_SPILLS) list.push(byId[i]);
				}
			}
			spills.set(id, list);
		}
	}

	static inline var MAX_SHARED = 4096; // (reference locals; beyond: no sharing)

	// ---- the raw-address check (Facts.checkRawAddresses)

	// where a raw heap address of f is live across a GC point or passed to
	// one (empty: none): the liveness above, over the locals that hold such
	// addresses (assigned from Mem.addr or arithmetic on one)
	public static function rawViolations(f:FuncInfo):Array<String> {
		var r = new Roots();
		var all = f.args.concat(f.locals);
		var n = 0;
		for (l in all)
			if (l.id >= n) n = l.id + 1;
		r.n = n;
		r.byId = new haxe.ds.Vector(n);
		r.refs = new Bits(n);
		for (l in all)
			r.byId[l.id] = l;
		r.rooted = new Bits(n);
		r.refIdx = hxmc.Lir.Arrays.filled(n, -1);
		r.raws = rawLocals(f, n);
		r.seq(f.body, new Bits(n));
		return r.rawErrors;
	}

	// the locals that may hold a raw heap address: the largest fixpoint of
	// "assigned an expression derived from Mem.addr or from such a local"
	static function rawLocals(f:FuncInfo, n:Int):Bits {
		var raw = new Bits(n);
		var sets:Array<{l:Local, e:Ex}> = [];
		function st(s:Stmt) {
			switch s {
				case SSet(l, e): sets.push({l: l, e: e});
				case _:
			}
			hxmc.ir.Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in f.body)
			st(s);
		var changed = true;
		while (changed) {
			changed = false;
			for (x in sets)
				if (!raw.get(x.l.id) && derived(x.e, raw)) {
					raw.set(x.l.id);
					changed = true;
				}
		}
		return raw;
	}

	// whether e is (arithmetic on) the address of a heap object
	static function derived(e:Ex, raw:Bits):Bool
		return switch e {
			case ECallHost("hxmc_unsafe_Mem_addr", _, _) | EFieldAddr(_): true;
			case ELocal(l): raw.get(l.id);
			case EBin(LAdd | LSub | LAnd | LOr | LXor, a, b): derived(a, raw) || derived(b, raw);
			case ECast(_, a): derived(a, raw);
			case _: false;
		}

	// the arguments of a call that is a GC point: none may be a raw address
	function rawOperands(e:Ex) {
		var args = switch e {
			case ECall(_, xs) | ECallDispatch(_, _, xs) | ECallHost(_, xs, _): xs;
			case ECallClos(_, c, xs) | ECallAnon(_, _, c, xs): VectorTools.cons(c, xs);
			case _: vector();
		}
		for (a in args)
			if (derivedAny(a)) {
				var m = "is passed to " + point;
				if (rawErrors.indexOf(m) < 0) rawErrors.push(m);
				return;
			}
	}

	function derivedAny(e:Ex):Bool {
		var r = derived(e, raws);
		if (!r) hxmc.ir.Facts.iterEx(x -> if (!r && derivedAny(x)) r = true, e);
		return r;
	}

	static function pointName(e:Ex):String
		return switch e {
			case ECall(g, _): "a call of " + hxmc.ir.Facts.displayName(g);
			case ECallHost(n, _, _): (hxmc.ir.CInterop.BLOCKING.exists(n) ? "a call of the C function " : "a call of the runtime's ") + n;
			case ECallDispatch(_) | ECallClos(_) | ECallAnon(_): "a dynamic call";
			case ENewObj(_) | ENewEnum(_) | ENewArr(_) | ENewClos(_) | ENewBox(_) | ENewAnon(_) | EBox(_): "the allocation of " + hxmc.ir.Facts.allocName(e);
			case _: "a GC point (" + e.getName() + ")";
		}

	static function stmtPoint(s:Stmt):String
		return switch s {
			case SSet(_, e) | SExpr(e): pointName(e);
			case SArrSet(_) | SArrPush(_): "an array store (its slow path grows the array)";
			case SAnonSet(_): "a structural field store";
			case SCold(_, x): stmtPoint(x);
			case _: "a GC point (" + s.getName() + ")";
		}

	// local `id` is set where `live` are live (after the definition)
	function def(id:Int, live:Bits) {
		if (inter == null) return;
		var d = refIdx[id];
		if (d < 0) return;
		var row = inter[d];
		for (k in 0...live.w.length) {
			var x = live.w[k];
			while (x != 0) {
				var b = x & -x;
				var i = (k << 5) + bitIndex(b);
				x &= x - 1;
				var j = i < refIdx.length ? refIdx[i] : -1;
				if (j >= 0 && j != d) {
					row.set(j);
					inter[j].set(d);
				}
			}
		}
	}

	static inline function bitIndex(b:Int):Int {
		var i = 0;
		while (b != 1 && b != 0) {
			b >>>= 1;
			i++;
		}
		return i;
	}

	// the slots of the rooted locals: those in `zero` (whose slots start
	// null) after the others; a local in `alone` gets a slot of its own
	public function assign(all:Array<Local>, zero:Bits, alone:Bits):{slotOf:Map<Int, Int>, nslots:Int, nzero:Int} {
		var color = new Map<Int, Int>();
		var members:Array<Array<Int>> = [];
		for (l in all) {
			if (!rooted.get(l.id)) continue;
			var c = -1;
			if (inter != null && !alone.get(l.id)) {
				var row = inter[refIdx[l.id]];
				for (k in 0...members.length) {
					var ok = true;
					for (m in members[k])
						if (alone.get(m) || row.get(refIdx[m])) {
							ok = false;
							break;
						}
					if (ok) {
						c = k;
						break;
					}
				}
			}
			if (c < 0) {
				c = members.length;
				members.push([]);
			}
			members[c].push(l.id);
			color.set(l.id, c);
		}
		var zc = [for (ms in members) {
			var z = false;
			for (m in ms)
				if (zero.get(m)) z = true;
			z;
		}];
		var slotOf = new Map<Int, Int>();
		var next = 0;
		var renum = [for (_ in members) -1];
		for (pass in 0...2)
			for (k in 0...members.length)
				if (zc[k] == (pass == 1)) renum[k] = next++;
		var nzero = 0;
		for (k in 0...members.length)
			if (zc[k]) nzero++;
		for (id => c in color)
			slotOf.set(id, renum[c]);
		return {slotOf: slotOf, nslots: members.length, nzero: nzero};
	}

	inline function copy(b:Bits):Bits
		return b.copy();

	function union(a:Bits, b:Bits):Bits {
		var r = a.copy();
		r.union(b);
		return r;
	}

	function across(live:Bits) {
		var w = live.w, rw = refs.w, ro = rooted.w;
		for (k in 0...w.length)
			ro[k] |= w[k] & rw[k];
		if (raws != null)
			for (k in 0...n)
				if (live.get(k) && raws.get(k)) rawError(k, "is live across " + point);
	}

	function rawError(k:Int, what:String) {
		var m = "in " + (byId[k] != null ? byId[k].name : "a temporary") + " " + what;
		if (rawErrors.indexOf(m) < 0) rawErrors.push(m);
	}

	function uses(e:Ex, acc:Bits) {
		switch e {
			case ELocal(l): acc.set(l.id);
			case _: hxmc.ir.Facts.iterEx(x -> uses(x, acc), e);
		}
	}

	function seq(ss:Vector<Stmt>, out:Bits):Bits {
		var live = out;
		var i = ss.length;
		while (i-- > 0)
			live = stmt(ss[i], live);
		return live;
	}

	static function gcPoint(e:Ex):Int
		return hxmc.ir.Facts.GcPoints.gcPoint(e);

	static function nestedGc(e:Ex):Bool
		return hxmc.ir.Facts.GcPoints.nestedGc(e);

	function expr(e:Ex, after:Bits, def:Null<Local>):Bits {
		var rest = copy(after);
		if (def != null) {
			this.def(def.id, after);
			rest.clear(def.id);
		}
		var g = gcPoint(e);
		if (nestedGc(e)) g = 2;
		if (raws != null && g > 0) {
			point = pointName(e);
			if (g == 1) rawOperands(e);
		}
		if (g == 1) across(rest);
		uses(e, rest);
		if (g == 2) across(rest);
		return rest;
	}

	function cold(id:Int, s:Stmt, out:Bits):Bits {
		var live = copy(out);
		switch s {
			case SSet(l, e):
				def(l.id, out);
				live.clear(l.id);
				uses(e, live);
			case SArrSet(_, a, i, v):
				live.set(a.id);
				uses(i, live);
				uses(v, live);
			case SArrPush(_, a, v):
				live.set(a.id);
				uses(v, live);
			case SExpr(e):
				uses(e, live);
			case _:
				throw "cold statement";
		}
		// inside a try body the references a slow path reloads are assigned
		// there: they live in their slots (see analyze)
		if (extras.length > 0) {
			for (k in 0...n)
				if (live.get(k) && refs.get(k)) rooted.set(k);
		}
		if (raws != null) {
			point = "the slow path of " + stmtPoint(s);
			for (k in 0...n)
				if (live.get(k) && raws.get(k)) rawError(k, "is live across " + point);
		}
		// (the analysis may come here again for the site, in a loop: the union)
		var set = spillSets.get(id);
		if (set == null) spillSets.set(id, set = new Bits(n));
		var sw = set.w, lw = live.w, rw = refs.w;
		for (k in 0...sw.length)
			sw[k] |= lw[k] & rw[k];
		return live;
	}

	// per enclosing try body: what its handlers need (live wherever it may throw)
	var extras:Array<Bits> = [];

	function stmt(s:Stmt, out:Bits):Bits {
		if (s.match(SPos(_))) return out;
		var r = stmt0(s, out);
		if (extras.length > 0) r = union(r, extras[extras.length - 1]);
		return r;
	}

	function stmt0(s:Stmt, out:Bits):Bits {
		if (raws != null) point = stmtPoint(s);
		return switch s {
			case SCold(id, x): cold(id, x, out);
			case SSet(l, e): expr(e, out, l);
			case SExpr(e): expr(e, out, null);
			case SSetGlobal(_, v):
				var u = copy(out);
				uses(v, u);
				if (nestedGc(v) || gcPoint(v) > 0) across(u);
				u;
			case SSetField(_, _, o, v) | SBoxSet(_, o, v):
				var u = copy(out);
				uses(o, u);
				uses(v, u);
				if (nestedGc(o) || nestedGc(v) || gcPoint(v) > 0 || gcPoint(o) > 0) across(u);
				u;
			case SAnonSet(_, _, o, v):
				var u = copy(out);
				uses(o, u);
				uses(v, u);
				across(u);
				u;
			case SArrSet(_, a, i, v):
				rooted.set(a.id);
				var u = copy(out);
				u.set(a.id);
				uses(i, u);
				uses(v, u);
				across(u);
				u;
			case SArrPush(_, a, v):
				rooted.set(a.id);
				var u = copy(out);
				u.set(a.id);
				uses(v, u);
				across(u);
				u;
			case SIf(c, x, y):
				var u = union(seq(x, out), seq(y, out));
				uses(c, u);
				if (nestedGc(c) || gcPoint(c) > 0) across(u);
				u;
			case SLoop(body):
				var entry = new Bits(n);
				while (true) {
					brk.push(out);
					cont.push(entry);
					var nb = seq(body, entry);
					brk.pop();
					cont.pop();
					var u = union(entry, nb);
					if (same(u, entry)) break;
					entry = u;
				}
				entry;
			case SBreak: brk[brk.length - 1];
			case SContinue: cont[cont.length - 1];
			case SPos(_): out;
			case SSwitch(e, cases, def):
				var u = seq(def, out);
				for (c in cases)
					u = union(u, seq(c.body, out));
				uses(e, u);
				u;
			case SReturn(e):
				var u = new Bits(n);
				if (e != null) uses(e, u);
				u;
			case SThrow(e):
				var u = new Bits(n);
				uses(e, u);
				u;
			case STry(body, catches):
				// a handler may run after any point of the body (or the code after
				// the try, when no catch matches)
				var h = copy(out);
				// every catch variable is set at the handler's entry, before the
				// tests, which may collect (haxe.Exception.caught), and the first
				// is read again when none matches: they are defined together,
				// where what any handler reads is live
				var ins = new Bits(n);
				for (c in catches) {
					if (refs.get(c.l.id)) rooted.set(c.l.id);
					var u = seq(c.body, out);
					ins.union(u);
					u.clear(c.l.id);
					h = union(h, u);
				}
				for (c in catches)
					ins.set(c.l.id);
				for (c in catches)
					def(c.l.id, ins);
				if (extras.length > 0) h = union(h, extras[extras.length - 1]);
				// what the handlers need is live across a GC point: their tests
				// may collect (haxe.Exception.caught), and a handler is entered
				// from any point of the body, not only from its GC points (a
				// null access: the native targets' fault handler, hxmc.rt.Faults,
				// or an explicit test's throw); rooted, it is in its slot there
				across(h);
				extras.push(h);
				var b = seq(body, union(out, h));
				extras.pop();
				union(b, h);
		}
	}

	static function same(a:Bits, b:Bits):Bool {
		for (k in 0...a.w.length)
			if (a.w[k] != b.w[k]) return false;
		return true;
	}

	// ---- locals that may be read before any assignment (the arguments are set)

	public static function maybeUnset(f:FuncInfo):Bits {
		var n = 0;
		for (l in f.args.concat(f.locals))
			if (l.id >= n) n = l.id + 1;
		var bad = new Bits(n);
		function reads(e:Ex, set:Bits) {
			switch e {
				case ELocal(l):
					if (!set.get(l.id)) bad.set(l.id);
				case _:
					hxmc.ir.Facts.iterEx(x -> reads(x, set), e);
			}
		}
		function inter(a:Bits, b:Bits):Bits {
			var r = a.copy();
			for (k in 0...r.w.length)
				r.w[k] &= b.w[k];
			return r;
		}
		var step:(Stmt, Bits) -> Bits = null;
		function seq(ss:Vector<Stmt>, set:Bits):Bits {
			for (st in ss)
				set = step(st, set);
			return set;
		}
		step = function(st:Stmt, set:Bits):Bits {
			switch st {
				case SSet(l, e):
					reads(e, set);
					var r = set.copy();
					r.set(l.id);
					return r;
				case SExpr(e) | SThrow(e) | SSetGlobal(_, e):
					reads(e, set);
				case SReturn(e):
					if (e != null) reads(e, set);
				case SSetField(_, _, o, v) | SBoxSet(_, o, v) | SAnonSet(_, _, o, v):
					reads(o, set);
					reads(v, set);
				case SArrSet(_, a, i, v):
					if (!set.get(a.id)) bad.set(a.id);
					reads(i, set);
					reads(v, set);
				case SArrPush(_, a, v):
					if (!set.get(a.id)) bad.set(a.id);
					reads(v, set);
				case SIf(c, x, y):
					reads(c, set);
					return inter(seq(x, set.copy()), seq(y, set.copy()));
				case SLoop(body):
					seq(body, set.copy());
				case SSwitch(e, cases, def):
					reads(e, set);
					var r = seq(def, set.copy());
					for (c in cases)
						r = inter(r, seq(c.body, set.copy()));
					return r;
				case SCold(_, x):
					return step(x, set);
				case SBreak | SContinue | SPos(_):
				case STry(body, catches):
					// a handler may run before any assignment of the body
					var r = seq(body, set.copy());
					for (c in catches) {
						var h = set.copy();
						h.set(c.l.id);
						if (c.test != null) reads(c.test(ELocal(c.l)), h);
						r = inter(r, seq(c.body, h));
					}
					return r;
			}
			return set;
		};
		var entry = new Bits(n);
		for (a in f.args)
			entry.set(a.id);
		seq(f.body, entry);
		return bad;
	}
}
