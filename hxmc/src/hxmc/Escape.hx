package hxmc;

import haxe.ds.Vector;
import hxmc.Mir;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Escape analysis with scalar replacement (after inlining, before Sroa and
// Opt): an allocation that never leaves its function is replaced by its
// fields in SSA values, and is not made at all.
//
// The allocations are MirBuild's: the inline bump allocation of an object
// (a phi of the fast path's address and the slow path's stub call,
// MirBuild.alloc: class instances, anonymous objects, enum values,
// closures, the boxes of captured variables) and the runtime's boxing of an
// Int, Float or Int64 into a Dynamic (hx_box_int, hx_box_float,
// hx_box_i64). An allocation's aliases are its value, its copies, phis of
// aliases only, and what is read back from a shadow-stack slot or a cold
// site's spill area it was stored into ("cells": variables whose stores
// reach their loads; a collection moves objects but keeps what a slot
// refers to). Allocations that meet at a phi form a group, replaced
// together when their layouts agree: the group's fields are one set of
// variables, which is right only when every use of an alias is a use of
// the group's latest instance (checked: the alias's instance is the
// group's reaching allocation at the use; an object's allocation counts
// from its first use, so its constructor's arguments may still read the
// previous one). An alias may be read and written at constant offsets
// (fields, the header), compared with null, given to the write barrier
// (which an object that is never made does not need), stored into a cell
// and, for a box, unboxed; anything else (a call, a return, a store into
// the heap or a global, a phi with another value, an identity comparison)
// is an escape, and the group stays as it is. An object stored into
// another one's field escapes too (phase 1: one level of objects).
//
// Before that, the type index of any alias (escaping or not) is known: the
// inline caches' and enum switches' tests on it fold, so their slow paths
// (which take the object) go first. A screen keeps the analysis to the
// allocations that may stay in the function or have such tests.
class Escape {
	static inline var EMPTY = -1; // lattice: no allocation seen (yet)
	static inline var TOP = -2; // lattice: anything else, or several groups
	static inline var UNDEF = -2; // abstract value: no store reaches (the variable's entry)
	static inline var NONE = -3; // no definition in the block
	static inline var NOTSET = -4;

	public static var on = Sys.getEnv("HXMC_ESCAPE") != "0";

	// (debugging: HXMC_ESCAPE_HASH=<lo>-<hi>, the functions whose names hash
	// to lo...hi of 0...1024 only; HXMC_ESCAPE_NO=<parts>, parts off:
	// closures, frames, again, boxes, replace, screen)
	static var hashRange:Null<Array<Int>> = {
		var e = Sys.getEnv("HXMC_ESCAPE_HASH");
		e == null ? null : [for (x in e.split("-")) Std.parseInt(x)];
	};
	static var no = Sys.getEnv("HXMC_ESCAPE_NO") ?? "";

	public static function allowed(name:String):Bool {
		if (hashRange == null) return true;
		var h = 0;
		for (k in 0...name.length)
			h = (h * 31 + StringTools.fastCodeAt(name, k)) & 0xFFFFFF;
		h = h % 1024;
		return h >= hashRange[0] && h < hashRange[1];
	}

	public static inline function part(p:String):Bool
		return no.indexOf(p) < 0;

	// the enum constructors by the symbol of their type index: the enum's
	// number and the tag (Driver sets it before compiling; read only)
	public static var ctorTags:Null<Map<String, {en:Int, tag:Int}>>;

	// per type (the symbol of its index, or #index), which slots hold
	// references (Driver sets it; read only)
	public static var refSlots:Null<Map<String, Vector<Bool>>>;

	// (HXMC_ESCAPE_LOG=1) what happens to each allocation that is analyzed
	static var log = Sys.getEnv("HXMC_ESCAPE_LOG") == "1";

	var f:MFunc;

	public var removed = 0; // allocation sites replaced
	public var folds = 0; // tests folded on known type indices

	var nv = 0; // values when analyzed: abstract values below are Mir values, from here virtual phis
	var nb = 0; // block numbers
	var sites:Array<Site> = [];
	var siteOf:Vector<Int>; // the value of a site -> its index (-1)
	// the uses of each value (CSR)
	var useStart:Vector<Int>;
	var useList:Vector<MIns>;
	// virtual phis (of cells, and of the latest instance of a group)
	var vpBlock:Array<MBlock> = [];
	var vpArgs:Array<Vector<Int>> = [];
	// cells: shadow-stack slots and spill areas at constant offsets
	var cellOf:Vector<Int>; // load or store -> its cell + 1 (0: none)
	var rootDone:Vector<Bool>; // rt_sp values whose accesses are known
	var cellTracked:Array<Bool> = [];
	var cellLoads:Array<Array<MIns>> = [];
	var cellStores:Array<Array<MIns>> = [];
	var cellDone:Array<Bool> = [];
	var cellVps:Array<Array<Int>> = [];
	var reach:Vector<Int>; // cell load -> the abstract value stored (NOTSET)
	var ends:Vector<Int>; // (scratch, by block: NONE)
	var memo:Vector<Int>; // (scratch, by block: NOTSET)
	// the alias lattice, by abstract value
	var src:Vector<Int>;
	var cap = 0; // (of src, inSet, repl: values and virtual phis)
	var inSet:Vector<Bool>;
	var repl:Vector<Int>; // trivial phis -> their value (-1)
	var closure:Array<Int> = [];
	var parent:Vector<Int> = vector(); // union-find of sites
	var escaped:Vector<Bool> = vector();
	var uniform:Vector<Bool> = vector();
	var whys:Vector<Null<String>> = vector();
	var lastFail:Null<MIns>;

	public function new(f:MFunc)
		this.f = f;

	public function run() {
		if (f.allocs == 0 || !allowed(f.name)) return;
		for (b in f.blocks)
			for (i in b.ins)
				if (i.op == Call && i.returnsTwice) return;
		// (again after a replacement: an object stored into a replaced one's
		// field no longer is)
		for (_ in 0...(part("again") ? 3 : 1))
			if (!once()) break;
	}

	function once():Bool {
		screenFolds = 0;
		curReaders = new Map();
		frameTop = null;
		for (round in 0...3) {
			if (!findSites()) return false;
			if (round == 0) deadPhis();
			analyze();
			if (round == 2 || !foldKnown()) break;
		}
		if (!part("replace")) return false;
		var groups = check();
		var any = false;
		for (g in groups)
			if (replace(g)) any = true else escape(g.root, "fields overlap");
		if (log) report();
		if (!any) return false;
		sweep();
		prune();
		trivialPhis();
		if (part("frames")) elideFrames();
		return true;
	}

	// shadow-stack frames left holding only nulls (their objects replaced)
	// are not pushed at all
	function elideFrames() {
		nv = f.vals.length;
		buildUses();
		var gone = false;
		for (b in f.blocks)
			for (r in b.ins)
				if (!r.dead && r.op == TlsLoad && r.sym == "rt_sp" && elide(r)) gone = true;
		if (gone) sweep();
	}

	function elide(r:MIns):Bool {
		var kill:Array<MIns> = [], cmps:Array<MIns> = [];
		var pushed = false;
		var work = [r.id], top = 1;
		while (top > 0) {
			var v = work[--top];
			for (q in useStart[v]...useStart[v + 1]) {
				var u = useList[q];
				if (u.dead) continue;
				switch u.op {
					case Store if (u.a == v && u.b < 0 && u.c != v && isConst(u.c, 0)):
						kill.push(u);
					case TlsStore if (u.sym == "rt_sp" && u.a == v):
						// (the pop, or the push of a frame of constant size)
						if (v != r.id) pushed = true;
						kill.push(u);
					case TlsStore if (u.sym == "rt_sp_hw" && u.a == v):
						kill.push(u);
					case Cmp if (v != r.id && u.imm == CUGt && u.a == v):
						cmps.push(u);
					case Add if (u.a == v && u.b != v && constOf(u.b) != null && constOf(u.b).sym == null):
						work[top++] = u.id;
					case _:
						return false;
				}
			}
		}
		if (!pushed) return false;
		for (u in kill)
			u.dead = true;
		for (u in cmps)
			toConst(u, 0);
		return true;
	}

	// ---- closures called where they are made

	// The indirect calls of f through closures whose function is known (a
	// closure made here, possibly kept in a shadow-stack slot that holds only
	// closures of that function) become direct calls of it, returned (the
	// Driver inlines them, then the closure is an object like any other).
	public static function closureCalls(f:MFunc):Array<{call:MIns, sym:String}> {
		var r = [];
		var calls = [];
		for (b in f.blocks)
			for (i in b.ins)
				if (!i.dead && i.op == Call && i.sym == null && i.a >= 0 && i.args.length > 0) calls.push(i);
		if (calls.length == 0) return r;
		var e = new Escape(f);
		var nv = f.vals.length;
		var fn = new Vector<Null<String>>(nv); // values that are closures of a known function
		var any = false;
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Phi:
						var s = e.objectSite(i);
						if (s != null) {
							var d = s.defAt;
							if (d.op == Store && d.a == i.id && d.b < 0 && d.imm == 0 && d.size == 8) {
								var c = f.vals[d.c];
								while (c.op == Copy)
									c = f.vals[c.a];
								if (c.op == SymAddr && c.imm == 0 && c.sym != null) {
									fn[i.id] = c.sym;
									any = true;
								}
							}
						} else
							fn[i.id] = e.sameSym(fn, i);
					case Copy:
						fn[i.id] = fn[i.a];
					case _:
				}
			}
		if (!any) return r;
		// (slots that only ever hold closures of one function)
		var slots = new Map<Int, String>();
		for (b in f.blocks)
			for (i in b.ins)
				if (!i.dead && i.op == Store) {
					var k = e.slotKey(i);
					if (k < 0) continue;
					var s = fn[i.c], o = slots.get(k);
					slots.set(k, s == null || o != null && o != s ? "" : s);
				}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Load if (i.ty == I64 && fn[i.id] == null):
						var k = e.slotKey(i);
						var s = k < 0 ? null : slots.get(k);
						if (s != null && s != "") fn[i.id] = s;
					case Copy if (fn[i.id] == null):
						fn[i.id] = fn[i.a];
					case Phi if (fn[i.id] == null):
						fn[i.id] = e.sameSym(fn, i);
					case _:
				}
			}
		for (c in calls) {
			var l = f.vals[c.a];
			while (l.op == Copy)
				l = f.vals[l.a];
			if (l.op != Load || l.b >= 0 || l.imm != 0 || l.size != 8) continue;
			var s = fn[l.a];
			if (s == null || c.args[0] != l.a && fn[c.args[0]] != s) continue;
			c.sym = s;
			c.a = -1;
			r.push({call: c, sym: s});
		}
		if (r.length == 0) return r;
		// (inlined only where the closure may then be replaced: not where it
		// certainly escapes otherwise, the screen says, but by these calls)
		e.ignore = [for (x in r) x.call.id => true];
		e.findSites();
		var d = e.screenDer, sure = e.screenSure;
		return [
			for (x in r)
				if (!x.call.dead && d != null && d[x.call.args[0]] >= 0 && !sure[d[x.call.args[0]]]) x
		];
	}

	var ignore:Null<Map<Int, Bool>>; // (the screen: calls that are no escape)
	var screenDer:Null<Vector<Int>>; // (what the screen found: the site each value may be, and the sites that escape)
	var screenSure:Null<Vector<Bool>>;

	// a phi's operands' function when they agree (null: not all known closures of one)
	function sameSym(fn:Vector<Null<String>>, i:MIns):Null<String> {
		var s:Null<String> = null;
		for (a in i.args) {
			if (a == i.id) continue;
			var x = fn[a];
			if (x == null || s != null && s != x) return null;
			s = x;
		}
		return s;
	}

	// ---- allocation sites

	// the sites worth analyzing: false when none (an object or box with a use
	// that certainly escapes, outside slow paths, and no test to fold is left
	// alone)
	function findSites():Bool {
		nv = f.vals.length;
		nb = 0;
		for (b in f.blocks)
			if (b.id >= nb) nb = b.id + 1;
		// the sites; what their values reach through copies and phis (der:
		// roughly, a screen; exact: copies, and phis of one site only)
		var all = [];
		var der = MFunc.ints(nv, -1), exact = MFunc.ints(nv, -1);
		// (sites meeting at a phi go together: one escapes, all do)
		var uf:Array<Int> = [], mergeOut:Array<MIns> = [];
		function root(k:Int):Int {
			while (uf[k] != k)
				k = uf[k] = uf[uf[k]];
			return k;
		}
		// a phi of sites only: their group
		function phiDer(i:MIns):Int {
			var d = NONE;
			for (a in i.args)
				if (a != i.id) {
					var x = der[a];
					if (x < 0) {
						// (with a constant, a parameter or a call's result: those sites escape)
						var op = f.vals[a].op;
						if (op == Const || op == Param || op == Call && der[a] == -1) mergeOut.push(i);
						return -1;
					}
					x = root(x);
					if (d == NONE) d = x else if (d != x) {
						if (x < d) {
							uf[d] = x;
							d = x;
						} else uf[x] = d;
					}
				}
			return d == NONE ? -1 : d;
		}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				var s:Null<Site> = null;
				switch i.op {
					case Phi:
						s = objectSite(i);
						if (s == null) {
							var e = NONE;
							for (a in i.args)
								if (a != i.id) e = e == NONE || e == exact[a] ? exact[a] : -1;
							if (e >= 0) exact[i.id] = e;
							der[i.id] = phiDer(i);
						}
					case Copy:
						der[i.id] = der[i.a];
						exact[i.id] = exact[i.a];
					case Call if (i.sym != null && i.args.length == 1 && i.sym.length >= 10 && StringTools.fastCodeAt(i.sym, 3) == "b".code):
						var k = switch i.sym {
							case "hx_box_int": 1;
							case "hx_box_float": 2;
							case "hx_box_i64": 3;
							case _: 0;
						};
						if (k > 0 && part("boxes")) {
							s = new Site(i, i.block);
							s.defAt = i;
							s.box = k;
							s.key = "box" + k;
						}
					case _:
				}
				if (s != null) {
					der[i.id] = exact[i.id] = all.length;
					uf.push(all.length);
					all.push(s);
				}
			}
		if (all.length == 0) return false;
		// (what is read back from shadow-stack slots and spill areas they were stored into)
		// (a slot several sites were stored into: the load is any of them, der
		// -10 - its index in multi)
		var slots:Null<Map<Int, Int>> = null;
		var multi:Array<Array<Int>> = [];
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead || i.op != Store || i.c < 0 || der[i.c] < 0) continue;
				var k = slotKey(i);
				if (k < 0) continue;
				if (slots == null) slots = new Map();
				var o = slots.get(k), d = root(der[i.c]);
				if (o == null) slots.set(k, d) else if (o >= 0 && o != d) {
					slots.set(k, -2); // (several sites: the loads are none of them)
					multi.push([o, d]);
				} else if (o <= -10 && multi[-10 - o].indexOf(d) < 0) multi[-10 - o].push(d);
			}
		if (slots != null)
			for (b in f.blocks)
				for (i in b.ins) {
					if (i.dead) continue;
					if (i.op == Load && i.ty == I64 && der[i.id] == -1) {
						var k = slotKey(i);
						if (k >= 0 && slots.exists(k) && slots.get(k) >= 0) der[i.id] = slots.get(k);
					} else if (i.op == Copy && der[i.id] == -1) der[i.id] = der[i.a];
				}
		var sure = new Vector<Bool>(all.length);
		inline function isDer(v:Int):Bool
			return v >= 0 && der[v] != -1;
		function markSure(v:Int) {
			var d = der[v];
			if (d >= 0) sure[root(d)] = true;
		}
		var tindex:Array<MIns> = [], nulls:Array<MIns> = [];
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Phi if (der[i.id] == -1):
						der[i.id] = phiDer(i);
					case Copy if (der[i.id] == -1):
						der[i.id] = der[i.a];
					case Load if (i.imm == Abi.HDR_TINDEX && i.size == 2 && i.b < 0 && exact[i.a] >= 0):
						if (all[exact[i.a]].box == 0) tindex.push(i);
					case Cmp if ((i.imm == CEq || i.imm == CNe) && (exact[i.a] >= 0 && isConst(i.b, 0) || exact[i.b] >= 0 && isConst(i.a, 0))):
						nulls.push(i);
					case _ if (b.cold):
					case Call if (ignore == null || !ignore.exists(i.id)):
						var any = isDer(i.a);
						for (a in i.args)
							if (isDer(a)) any = true;
						if (any && i.sym != "hxmc_barrier_slow" && (i.sym == null || !StringTools.startsWith(i.sym, "hx_unbox_"))) {
							if (isDer(i.a)) markSure(i.a);
							for (a in i.args)
								if (isDer(a)) markSure(a);
						}
					case Ret | TlsStore if (isDer(i.a)):
						markSure(i.a);
					case Store if (isDer(i.c) && (i.mem == Opt.MField || i.mem == Opt.MElem || i.mem == Opt.MGlobal || i.mem == Opt.MInit)):
						markSure(i.c);
					case _:
				}
			}
		// the allocations that certainly escape: their tests fold here (on
		// their exact aliases), the analysis is for the others
		for (i in mergeOut)
			for (a in i.args)
				if (a != i.id && der[a] >= 0) sure[root(der[a])] = true;
		var n = 0;
		if (!part("screen")) sure = new Vector<Bool>(all.length); // (debugging: everything analyzed)
		for (i in tindex)
			if (sure[root(exact[i.a])]) {
				var tc = constOf(all[exact[i.a]].ty.c);
				i.op = Const;
				i.a = -1;
				i.sym = tc.sym;
				i.imm = tc.imm;
				i.imm2 = tc.imm2;
				i.size = 0;
				i.mem = 0;
				n++;
			}
		for (i in nulls)
			if (exact[i.a] >= 0 && sure[root(exact[i.a])] || exact[i.b] >= 0 && sure[root(exact[i.b])]) {
				toConst(i, i.imm == CEq ? 0 : 1);
				n++;
			}
		if (n > 0) {
			folds += n;
			constFold();
			prune();
			if (++screenFolds < 3) return findSites();
		}
		for (k in 0...all.length)
			if (sure[root(k)]) sure[k] = true;
		screenDer = der;
		screenSure = sure;
		sites = [];
		siteOf = MFunc.ints(nv, -1);
		for (k in 0...all.length)
			if (!sure[k]) {
				siteOf[all[k].v.id] = sites.length;
				sites.push(all[k]);
			}
		return sites.length > 0;
	}

	var screenFolds = 0;

	// (the screen) a load's or store's slot when its address is rt_sp plus a constant (-1: other memory)
	function slotKey(i:MIns):Int {
		if (i.b >= 0 || i.size != 8) return -1;
		var v = i.a, off = i.imm, n = 0;
		while (n++ < 16) {
			var x = f.vals[v];
			if (x.op == Copy) v = x.a else if (x.op == Add) {
				var c = constOf(x.b);
				if (c == null || c.sym != null) return -1;
				off += c.imm;
				v = x.a;
			} else break;
		}
		var r = f.vals[v];
		return r.op == TlsLoad && r.sym == "rt_sp" ? r.id * 1024 + ((off >> 3) & 1023) : -1;
	}

	inline function constOf(v:Int):Null<MIns> {
		var c = f.vals[v];
		while (c.op == Copy)
			c = f.vals[c.a];
		return c.op == Const ? c : null;
	}

	function isConst(v:Int, k:Int):Bool {
		var c = constOf(v);
		return c != null && c.sym == null && c.imm == k && c.imm2 == (k < 0 ? -1 : 0);
	}

	// MirBuild.alloc's shape: head: ptr = young_ptr ... br (enough room) fast, slow;
	// fast: young_ptr = ptr + bytes, the header's two words, ptr + 8; join: phi(ptr + 8, stub())
	function objectSite(p:MIns):Null<Site> {
		if (p.ty != I64 || p.args.length != 2) return null;
		var j = p.block;
		if (j.preds.length != 2) return null;
		for (k in 0...2) {
			var o = f.vals[p.args[k]], r = f.vals[p.args[1 - k]];
			if (o.op != Add || r.op != Call || r.sym == null || !StringTools.startsWith(r.sym, MirBuild.ALLOC_STUB)) continue;
			var fast = o.block;
			if (j.preds[k] != fast || fast.preds.length != 1 || fast.succs.length != 1) continue;
			var ptr = f.vals[o.a];
			if (ptr.op != TlsLoad || ptr.sym != "rt_young_ptr" || !isConst(o.b, 8)) continue;
			var head = fast.preds[0];
			var br = head.term();
			if (ptr.block != head || br == null || br.op != Br || br.targets[0] != fast || br.targets[1] == fast) continue;
			var tls:MIns = null, hdr:MIns = null, ty:MIns = null, bytes = -1;
			var ok = true;
			for (i in fast.ins) {
				if (i.dead) continue;
				switch i.op {
					case Const | Jmp:
					case Add if (i.a == ptr.id):
					case TlsStore if (i.sym == "rt_young_ptr" && tls == null):
						var a = f.vals[i.a];
						var c = a.op == Add && a.a == ptr.id ? constOf(a.b) : null;
						if (c == null || c.sym != null) ok = false else {
							tls = i;
							bytes = c.imm;
						}
					case Store if (i.a == ptr.id && i.b < 0 && i.size == 4 && i.imm == 0 && hdr == null):
						hdr = i;
					case Store if (i.a == ptr.id && i.b < 0 && i.size == 4 && i.imm == 4 && ty == null):
						ty = i;
					case _:
						ok = false;
				}
			}
			if (!ok || tls == null || hdr == null || ty == null || bytes < 16 || bytes & 7 != 0) continue;
			var hc = constOf(hdr.c), tc = constOf(ty.c);
			if (hc == null || tc == null || hc.sym != null) continue;
			// (an array: the runtime takes it for any growth; not worth the analysis)
			if (tc.sym == null && tc.imm == Abi.T_ARRAY) return null;
			var s = new Site(p, j);
			// (its values are defined where it is first used: what the block
			// computes before, its constructor's arguments, may read the
			// previous instance of its group)
			s.defAt = j.term();
			for (i in j.ins) {
				if (i.dead || i.op == Phi) continue;
				if (i.a == p.id || i.b == p.id || i.c == p.id || i.args.indexOf(p.id) >= 0) {
					s.defAt = i;
					break;
				}
			}
			if (s.defAt == null) return null;
			s.head = head;
			s.fast = fast;
			s.tls = tls;
			s.hdr = hdr;
			s.ty = ty;
			s.nslots = (bytes >> 3) - 1;
			s.hdrImm = hc.imm;
			s.tySym = tc.sym;
			s.tyImm = tc.imm;
			return s;
		}
		return null;
	}

	// ---- analysis

	// phis and copies nothing (but such) uses go first: MirBuild leaves
	// unused phis, which would merge aliases with other values
	function deadPhis() {
		var live = new Vector<Bool>(f.vals.length);
		var work = new Vector<Int>(f.vals.length), top = 0;
		inline function mark(v:Int) {
			if (v >= 0 && !live[v]) {
				live[v] = true;
				var i = f.vals[v];
				if (i.op == Phi || i.op == Copy) work[top++] = v;
			}
		}
		for (s in sites)
			mark(s.v.id);
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead || i.op == Phi || i.op == Copy) continue;
				mark(i.a);
				mark(i.b);
				mark(i.c);
				for (x in i.args)
					mark(x);
			}
		while (top > 0) {
			var i = f.vals[work[--top]];
			mark(i.a);
			for (x in i.args)
				mark(x);
		}
		for (b in f.blocks) {
			var ins = b.ins, k = 0;
			for (i in ins) {
				if ((i.op == Phi || i.op == Copy) && !live[i.id]) i.dead = true;
				if (!i.dead) ins[k++] = i;
			}
			if (k < ins.length) ins.resize(k);
		}
	}

	function buildUses() {
		var count = new Vector<Int>(nv + 1);
		var last = MFunc.ints(nv, -1); // (an instruction using a value twice is one use)
		inline function scan(fill:Bool) {
			for (b in f.blocks)
				for (i in b.ins) {
					if (i.dead) continue;
					inline function use(v:Int)
						if (v >= 0 && last[v] != i.id) {
							last[v] = i.id;
							if (fill) useList[count[v]++] = i else count[v + 1]++;
						}
					use(i.a);
					use(i.b);
					use(i.c);
					for (x in i.args)
						use(x);
				}
		}
		scan(false);
		for (v in 0...nv)
			count[v + 1] += count[v];
		useStart = new Vector<Int>(nv + 1);
		for (v in 0...nv + 1)
			useStart[v] = count[v];
		useList = new Vector<MIns>(count[nv]);
		last.fill(-1);
		scan(true);
	}

	function analyze() {
		buildUses();
		vpBlock = [];
		vpArgs = [];
		// (the value numbers stay the same from one round to the next: the
		// arrays are made once)
		if (reach == null || reach.length != nv) {
			reach = new Vector(nv);
			cellOf = new Vector(nv);
			rootDone = new Vector(nv);
			cap = nv + 64;
			src = new Vector(cap);
			inSet = new Vector(cap);
			repl = new Vector(cap);
		} else {
			cellOf.fill(0);
			rootDone.fill(false);
			inSet.fill(false);
		}
		reach.fill(NOTSET);
		src.fill(EMPTY);
		repl.fill(-1);
		if (ends == null || ends.length != nb) {
			ends = MFunc.ints(nb, NONE);
			memo = MFunc.ints(nb, NOTSET);
		}
		cellTracked = [];
		cellLoads = [];
		cellStores = [];
		cellDone = [];
		cellVps = [];
		parent = MFunc.iota(sites.length);
		escaped = new Vector(sites.length);
		whys = new Vector(sites.length);
		// the closure: what may be an alias
		closure = [];
		inline function add(x:Int) {
			if (!inSet[x]) {
				inSet[x] = true;
				closure.push(x);
			}
		}
		for (s in sites)
			add(s.v.id);
		var k = 0;
		while (k < closure.length) {
			var x = closure[k++];
			if (x >= nv) continue;
			for (q in useStart[x]...useStart[x + 1]) {
				var u = useList[q];
				switch u.op {
					case Copy | Phi:
						add(u.id);
					case Store if (u.c == x && u.a != x):
						var c = cellAt(u);
						if (c >= 0 && cellTracked[c]) {
							cellReach(c);
							for (l in cellLoads[c])
								add(l.id);
							for (v in cellVps[c])
								add(v);
						}
					case _:
				}
			}
		}
		// what each member of the closure is computed from: its users
		var na = nv + vpBlock.length;
		var users:Array<Null<Array<Int>>> = [];
		users.resize(na);
		for (x in closure)
			for (a in inputs(x))
				if (a >= 0 && inSet[a]) {
					var us = users[a];
					if (us == null) users[a] = [x] else us.push(x);
				}
		// the lattice, from below (a worklist)
		var work = new Vector<Int>(closure.length), top = 0;
		var queued = new Vector<Bool>(na);
		var j = closure.length;
		while (j-- > 0) {
			work[top++] = closure[j];
			queued[closure[j]] = true;
		}
		while (top > 0) {
			var x = work[--top];
			queued[x] = false;
			var n = compute(x);
			var o = src[x];
			if (o >= 0) o = find(o);
			if (n != o) {
				src[x] = n;
				var us = users[x];
				if (us != null)
					for (y in us)
						if (!queued[y]) {
							queued[y] = true;
							work[top++] = y;
						}
			}
		}
		for (x in closure) {
			var s = src[x];
			if (s >= 0) src[x] = find(s);
		}
		// one layout per group; (boxes) one per block
		uniform = new Vector(sites.length, true);
		var boxAt = new Map<Int, Int>();
		for (k in 0...sites.length) {
			var r = find(k);
			if (sites[r].layout() != sites[k].layout()) {
				uniform[r] = false;
				escape(r, "layouts differ");
			}
			if (sites[k].box > 0) {
				var o = boxAt.get(sites[k].block.id);
				if (o != null && find(o) == r) escape(r, "two boxes in a block");
				boxAt.set(sites[k].block.id, k);
			}
		}
		// trivial phis (of the closure) are their value
		var phis = [];
		for (x in closure)
			if (x >= nv || f.vals[x].op == Phi) phis.push(x);
		collapse(phis, users);
	}

	static var noInputs:Vector<Int> = vector();

	// the abstract values x is computed from (in the lattice)
	function inputs(x:Int):Vector<Int> {
		if (x >= nv) return vpArgs[x - nv];
		var i = f.vals[x];
		return switch i.op {
			case Copy: vector(i.a);
			case Phi: i.args;
			case Load if (reach[x] != NOTSET): vector(reach[x]);
			case _: noInputs;
		};
	}

	function find(k:Int):Int {
		while (parent[k] != k) {
			parent[k] = parent[parent[k]];
			k = parent[k];
		}
		return k;
	}

	function escape(s:Int, why:String) {
		var r = find(s);
		escaped[r] = true;
		if (log && whys[r] == null) whys[r] = why;
	}

	// the lattice's join: two groups meeting become one; a group meeting
	// anything else escapes
	function merge(a:Int, b:Int):Int {
		if (a == EMPTY) return b;
		if (b == EMPTY) return a;
		if (a == TOP || b == TOP) {
			if (a >= 0) escape(a, "merges with another value");
			if (b >= 0) escape(b, "merges with another value");
			return TOP;
		}
		var ra = find(a), rb = find(b);
		if (ra == rb) return ra;
		// (the smaller index the root: deterministic)
		var e = escaped[ra] || escaped[rb];
		var w = whys[ra] != null ? whys[ra] : whys[rb];
		if (rb < ra) {
			var t = ra;
			ra = rb;
			rb = t;
		}
		parent[rb] = ra;
		escaped[ra] = e;
		whys[ra] = w;
		return ra;
	}

	inline function absSrc(x:Int):Int {
		if (x < 0 || !inSet[x]) return TOP;
		var s = src[x];
		return s >= 0 ? find(s) : s;
	}

	// the source of an alias (a group's root), EMPTY or TOP
	inline function srcOf(x:Int):Int
		return x >= 0 && inSet[x] ? src[x] : TOP;

	function compute(x:Int):Int {
		if (x >= nv) {
			var r = EMPTY;
			for (a in vpArgs[x - nv])
				r = merge(r, absSrc(a));
			return r;
		}
		var s = siteOf[x];
		if (s >= 0) return find(s);
		var i = f.vals[x];
		return switch i.op {
			case Copy: absSrc(i.a);
			case Phi:
				var r = EMPTY;
				for (a in i.args)
					r = merge(r, a == x ? EMPTY : absSrc(a));
				r;
			case Load if (reach[x] != NOTSET): absSrc(reach[x]);
			case _: TOP;
		};
	}

	// phis whose operands are one value (or the phi) are that value (users:
	// what is computed from what, to look at again when a phi collapses;
	// null: every phi again until nothing changes)
	function collapse(phis:Array<Int>, ?users:Array<Null<Array<Int>>>) {
		if (users == null) {
			var changed = true;
			while (changed) {
				changed = false;
				for (p in phis)
					if (repl[p] < 0 && trivial(p)) changed = true;
			}
			return;
		}
		var work = [], top = 0;
		var j = phis.length;
		while (j-- > 0)
			work[top++] = phis[j];
		var next = [], nt = 0;
		while (top > 0) {
			var p = work[--top];
			if (repl[p] >= 0 || !trivial(p)) continue;
			// (its users, through copies and cell loads, resolve further)
			next[nt++] = p;
			while (nt > 0) {
				var us = users[next[--nt]];
				if (us != null)
					for (y in us)
						if (y >= nv || f.vals[y].op == Phi) work[top++] = y else next[nt++] = y;
			}
		}
	}

	// whether phi p (real or virtual) has one operand but itself (then it is that: repl)
	function trivial(p:Int):Bool {
		var args = p >= nv ? vpArgs[p - nv] : f.vals[p].args;
		var same = NONE;
		for (a in args) {
			var x = resolve(a);
			if (x == p || x == same) continue;
			if (same != NONE) return false;
			same = x;
		}
		if (same == NONE) return false;
		repl[p] = same;
		return true;
	}

	// the value behind copies, trivial phis and cell loads
	function resolve(x:Int):Int {
		var n = 0;
		while (x >= 0 && n++ < 1000000) {
			var r = repl[x];
			if (r >= 0) {
				x = r;
				continue;
			}
			if (x >= nv) break;
			var i = f.vals[x];
			if (i.op == Copy) {
				x = i.a;
				continue;
			}
			if (i.op == Load && reach[x] != NOTSET) {
				x = reach[x];
				continue;
			}
			break;
		}
		return x;
	}

	function newVp(b:MBlock):Int {
		vpBlock.push(b);
		vpArgs.push(noInputs);
		var v = nv + vpBlock.length - 1;
		if (v >= cap) {
			var c = cap * 2;
			var s = new Vector<Int>(c), q = new Vector<Bool>(c), r = new Vector<Int>(c);
			s.fill(EMPTY);
			r.fill(-1);
			Vector.blit(src, 0, s, 0, cap);
			Vector.blit(inSet, 0, q, 0, cap);
			Vector.blit(repl, 0, r, 0, cap);
			src = s;
			inSet = q;
			repl = r;
			cap = c;
		}
		return v;
	}

	function setVpArgs(v:Int, args:Vector<Int>)
		vpArgs[v - nv] = args;

	// ---- cells

	// the cell store u writes (-1: none)
	function cellAt(u:MIns):Int {
		if (cellOf[u.id] > 0) return cellOf[u.id] - 1;
		// (its address: rt_sp, plus constants)
		var v = u.a, n = 0;
		while (n++ < 64) {
			var i = f.vals[v];
			if (i.op == Copy) v = i.a else if (i.op == Add && constOf(i.b) != null) v = i.a else break;
		}
		var r = f.vals[v];
		if (r.op != TlsLoad || r.sym != "rt_sp" || rootDone[v]) return cellOf[u.id] - 1;
		rootDone[v] = true;
		cellRoot(r);
		return cellOf[u.id] - 1;
	}

	// the accesses of one shadow-stack frame or spill area (an rt_sp value),
	// at constant offsets; an address that leaves (but as a call's argument:
	// the runtime's slot handles) keeps the whole area untracked
	function cellRoot(r:MIns) {
		var acc:Array<MIns> = [], accOff:Array<Int> = [];
		var all = false;
		var untrack:Array<Int> = [];
		var work = [r.id], workOff = [0], top = 1;
		while (top > 0 && !all) {
			top--;
			var v = work[top], off = workOff[top];
			for (q in useStart[v]...useStart[v + 1]) {
				var u = useList[q];
				switch u.op {
					case Load if (u.a == v && u.b < 0 && u.size == 8):
						acc.push(u);
						accOff.push(off + u.imm);
					case Store if (u.a == v && u.b < 0 && u.c != v && u.size == 8):
						acc.push(u);
						accOff.push(off + u.imm);
					case Add if (u.a == v && u.b != v):
						var c = constOf(u.b);
						if (c == null || c.sym != null || c.imm2 != (c.imm < 0 ? -1 : 0)) all = true else {
							work[top] = u.id;
							workOff[top++] = off + c.imm;
						}
					case Copy:
						work[top] = u.id;
						workOff[top++] = off;
					case TlsStore if ((u.sym == "rt_sp" || u.sym == "rt_sp_hw") && u.a == v):
					case Cmp:
					case Call if (u.a != v):
						untrack.push(off);
					case _:
						all = true;
				}
				if (all) {
					if (log) Sys.println('escape: ${f.name}: an untracked area: ' + MFunc.insString(u));
					break;
				}
			}
		}
		var at = new Map<Int, Int>();
		for (k in 0...acc.length) {
			var o = accOff[k];
			var c = at.get(o);
			if (c == null) {
				c = cellTracked.length;
				at.set(o, c);
				cellTracked.push(!all && untrack.indexOf(o) < 0);
				cellLoads.push([]);
				cellStores.push([]);
				cellDone.push(false);
				cellVps.push([]);
			}
			cellOf[acc[k].id] = c + 1;
			if (acc[k].op == Load) cellLoads[c].push(acc[k]) else cellStores[c].push(acc[k]);
		}
	}

	// the store reaching each load of cell c (virtual phis where they meet)
	function cellReach(c:Int) {
		if (cellDone[c]) return;
		cellDone[c] = true;
		var blocks:Array<MBlock> = [];
		var seen = f.newMark();
		for (l in [cellLoads[c], cellStores[c]])
			for (i in l)
				if (i.block.mark != seen) {
					i.block.mark = seen;
					blocks.push(i.block);
				}
		var early:Array<MIns> = [];
		for (b in blocks) {
			var cur = NONE;
			for (i in b.ins) {
				if (i.dead || cellOf[i.id] != c + 1) continue;
				if (i.op == Store) cur = i.c else if (cur != NONE) reach[i.id] = cur else early.push(i);
			}
			ends[b.id] = cur;
		}
		var first = vpBlock.length;
		var rd = new Reader(f.entry, UNDEF, ends, memo, newVp, setVpArgs);
		for (l in early)
			reach[l.id] = rd.readEntry(l.block);
		rd.finish();
		rd.reset();
		for (b in blocks)
			ends[b.id] = NONE;
		for (k in first...vpBlock.length)
			cellVps[c].push(nv + k);
	}

	// ---- folding on known type indices

	// the type index of an alias is its group's; an alias is not null; then
	// comparisons of equal constants, and branches and switches on constants
	function foldKnown():Bool {
		var n = 0;
		for (x in closure) {
			if (x >= nv) continue;
			var s = src[x];
			if (s < 0 || !uniform[s]) continue;
			var site = sites[s];
			for (q in useStart[x]...useStart[x + 1]) {
				var u = useList[q];
				if (u.dead) continue;
				switch u.op {
					case Load if (site.box == 0 && u.a == x && u.b < 0 && u.imm == Abi.HDR_TINDEX && u.size == 2):
						var tc = constOf(site.ty.c);
						u.op = Const;
						u.a = -1;
						u.sym = tc.sym;
						u.imm = tc.imm;
						u.imm2 = tc.imm2;
						u.size = 0;
						u.mem = 0;
						n++;
					case Cmp if ((u.imm == CEq || u.imm == CNe) && (u.a == x && isConst(u.b, 0) || u.b == x && isConst(u.a, 0))):
						toConst(u, u.imm == CEq ? 0 : 1);
						n++;
					case _:
				}
			}
		}
		if (n == 0) return false;
		folds += n;
		constFold();
		prune();
		return true;
	}

	function toConst(i:MIns, v:Int) {
		i.op = Const;
		i.a = -1;
		i.b = -1;
		i.c = -1;
		i.sym = null;
		i.imm = v;
		i.imm2 = v < 0 && i.ty == I64 ? -1 : 0;
		i.size = 0;
		i.mem = 0;
	}

	function constFold() {
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Cmp if (i.imm == CEq || i.imm == CNe):
						var x = constOf(i.a), y = constOf(i.b);
						if (x == null || y == null || x.ty != y.ty) continue;
						var eq = if (x.sym == y.sym && x.imm == y.imm && x.imm2 == y.imm2) 1 else if (x.sym == null && y.sym == null) 0 else if (x.sym != null
							&& y.sym != null && x.imm == 0 && y.imm == 0 && x.imm2 == 0 && y.imm2 == 0 && StringTools.startsWith(x.sym, "TY_")
							&& StringTools.startsWith(y.sym, "TY_")) 0 else -1;
						if (eq >= 0) toConst(i, i.imm == CEq ? eq : 1 - eq);
					case Sub if (i.ty == I32):
						var x = constOf(i.a), y = constOf(i.b);
						if (x == null || y == null || x.sym == null || y.sym == null || x.imm2 != 0 || y.imm2 != 0) continue;
						if (x.sym == y.sym) toConst(i, x.imm - y.imm) else {
							// (constructors of one enum: their type indices less their tags are the same)
							var tx = ctorTags == null ? null : ctorTags.get(x.sym), ty = ctorTags == null ? null : ctorTags.get(y.sym);
							if (tx != null && ty != null && tx.en == ty.en) toConst(i, tx.tag + x.imm - ty.tag - y.imm);
						}
					case Br:
						var c = constOf(i.a);
						if (c == null || c.sym != null) continue;
						jumpTo(b, i, c.imm != 0 || c.imm2 != 0 ? i.targets[0] : i.targets[1]);
					case Switch:
						var c = constOf(i.a);
						if (c == null || c.sym != null) continue;
						var to = i.targets[i.targets.length - 1];
						for (k in 0...i.cases.length)
							if (i.cases[k] == c.imm) {
								to = i.targets[k];
								break;
							}
						jumpTo(b, i, to);
					case _:
				}
			}
	}

	// b's terminator t becomes a jump to `to` (the edges to its other successors go)
	function jumpTo(b:MBlock, t:MIns, to:MBlock) {
		for (s in b.succs) {
			var keep = s == to;
			var k = 0;
			while (k < s.preds.length) {
				if (s.preds[k] == b) {
					if (keep) keep = false else {
						s.preds.splice(k, 1);
						for (i in s.ins)
							if (i.op == Phi && !i.dead) i.removeArg(k);
						continue;
					}
				}
				k++;
			}
		}
		t.op = Jmp;
		t.a = -1;
		t.cases = vector();
		t.targets = vector(to);
		b.succs = [to];
	}

	function prune() {
		var reachable = f.newMark();
		var stack = [f.entry];
		f.entry.mark = reachable;
		while (stack.length > 0) {
			var b = stack.pop();
			for (s in b.succs)
				if (s.mark != reachable) {
					s.mark = reachable;
					stack.push(s);
				}
		}
		var all = true;
		for (b in f.blocks) {
			if (b.mark == reachable) continue;
			all = false;
			for (s in b.succs) {
				var k = s.preds.indexOf(b);
				while (k >= 0) {
					s.preds.splice(k, 1);
					for (i in s.ins)
						if (i.op == Phi && !i.dead) i.removeArg(k);
					k = s.preds.indexOf(b);
				}
			}
			for (i in b.ins)
				i.dead = true;
		}
		if (!all) f.blocks = [for (b in f.blocks) if (b.mark == reachable) b];
	}

	// ---- the uses of the aliases

	// the groups that do not escape, with their accesses
	function check():Array<Group> {
		var acc = new Vector<Null<Group>>(sites.length);
		for (x in closure) {
			if (x >= nv) continue;
			var s = src[x];
			if (s < 0 || escaped[s]) continue;
			if (acc[s] == null) acc[s] = new Group(s);
			var g = acc[s];
			g.aliases.push(x);
			lastFail = null;
			if (!uses1(g, x, x, 0)) escape(s, failWhy(lastFail));
		}
		// the instance used is the group's latest
		for (g in acc) {
			if (g == null || escaped[g.root]) continue;
			for (k in 0...g.accesses.length)
				if (!latest(g, g.bases[k], g.accesses[k])) {
					escape(g.root, "not the latest instance");
					break;
				}
		}
		var r = [];
		for (k in 0...acc.length)
			if (acc[k] != null && !escaped[k]) {
				var g = acc[k];
				for (j in 0...sites.length)
					if (find(j) == k) g.sites.push(sites[j]);
				r.push(g);
			}
		return r;
	}

	// the uses of v, an alias x or an address off bytes into it (false: an escape)
	function uses1(g:Group, x:Int, v:Int, off:Int):Bool {
		var box = sites[g.root].box;
		for (q in useStart[v]...useStart[v + 1]) {
			var u = useList[q];
			if (u.dead) continue;
			lastFail = u;
			switch u.op {
				case Copy:
					if (v != x) {
						g.derived.push(u);
						if (!uses1(g, x, u.id, off)) return false;
					}
				case Phi:
					if (v != x) return false;
					var s = srcOf(u.id);
					if (s < 0 || find(s) != g.root) return false;
				case Load if (u.a == v && u.b != v && u.b < 0 && box == 0):
					g.access(u, x, off + u.imm);
				case Store if (u.a == v && u.b != v && u.b < 0 && u.c != v && box == 0):
					var c = srcOf(u.c);
					if (c >= 0) escape(c, "stored into an object"); // (phase 1)
					g.access(u, x, off + u.imm);
				case Store if (u.c == v && v == x && u.a != v && u.b != v && cellOf[u.id] > 0 && cellTracked[cellOf[u.id] - 1]):
					g.cellStores.push(u);
				case Add if (u.a == v && u.b != v && box == 0):
					var c = constOf(u.b);
					if (c == null || c.sym != null || c.imm2 != (c.imm < 0 ? -1 : 0)) return false;
					g.derived.push(u);
					if (!uses1(g, x, u.id, off + c.imm)) return false;
				case Sub if (u.a == v && v == x && youngStart(u.b) && box == 0):
					// the write barrier's test: the object is young
					for (r in useStart[u.id]...useStart[u.id + 1]) {
						var w = useList[r];
						if (!w.dead && (w.op != Cmp || w.imm != CULt || w.a != u.id)) return false;
					}
					g.derived.push(u);
					for (r in useStart[u.id]...useStart[u.id + 1])
						if (!useList[r].dead) g.young.push(useList[r]);
				case Cmp if ((u.imm == CEq || u.imm == CNe) && v == x && (u.a == v && isConst(u.b, 0) || u.b == v && isConst(u.a, 0))):
					g.nulls.push(u);
				case Call if (u.sym == "hxmc_barrier_slow" && box == 0 && u.args.length == 4 && u.args[2] != v && u.args[3] != v):
					g.barriers.push(u);
				case Call if (box > 0 && v == x && u.sym != null && u.args.length == 1 && unboxOk(box, u.sym)):
					g.access(u, x, 0);
				case _:
					return false;
			}
		}
		return true;
	}

	static function unboxOk(box:Int, sym:String):Bool
		return switch sym {
			case "hx_unbox_int": box == 1;
			case "hx_unbox_float": box == 1 || box == 2;
			case "hx_unbox_i64": box == 3;
			case _: false;
		};

	function youngStart(v:Int):Bool {
		var l = f.vals[v];
		if (l.op != Load || l.b >= 0 || l.imm != 0) return false;
		var a = f.vals[l.a];
		return a.op == SymAddr && a.sym == "rt_young_start" && a.imm == 0;
	}

	// ---- the latest instance

	var curReaders:Map<Int, Reader> = new Map();

	// where u uses alias x: the group's reaching allocation is x's instance
	function latest(g:Group, x:Int, u:MIns):Bool {
		var rd = curReaders.get(g.root);
		if (rd == null) {
			var defs = MFunc.ints(nb, NONE);
			for (k in 0...sites.length)
				if (find(k) == g.root) defs[sites[k].block.id] = sites[k].v.id;
			rd = new Reader(f.entry, UNDEF, defs, MFunc.ints(nb, NOTSET), newVp, setVpArgs);
			curReaders.set(g.root, rd);
		}
		var b = u.block;
		var cur = NONE;
		var d = rd.ends[b.id];
		if (d != NONE) {
			// (the allocation is made in the block: before u?)
			var at = sites[siteOf[d]].defAt;
			for (i in b.ins) {
				if (i == at) cur = d;
				if (i == u) break;
			}
		}
		if (cur == NONE) {
			var first = vpBlock.length;
			cur = rd.readEntry(b);
			rd.finish();
			if (vpBlock.length > first) collapse([for (k in first...vpBlock.length) nv + k]);
		}
		return same(x, cur);
	}

	// x and y are the same value: phis of one block with the same operands
	// (coinductively)
	function same(x:Int, y:Int):Bool {
		var wx = [x], wy = [y], top = 1;
		var assumed = new Map<String, Bool>();
		while (top > 0) {
			top--;
			var a = resolve(wx[top]), b = resolve(wy[top]);
			if (a == b) continue;
			if (a < 0 || b < 0) return false;
			var ba = phiBlock(a), bb = phiBlock(b);
			if (ba == null || ba != bb) return false;
			var key = a + ":" + b;
			if (assumed.exists(key)) continue;
			assumed.set(key, true);
			var xa = phiArgs(a), xb = phiArgs(b);
			if (xa.length != xb.length) return false;
			for (k in 0...xa.length) {
				wx[top] = xa[k];
				wy[top++] = xb[k];
			}
		}
		return true;
	}

	inline function phiBlock(v:Int):Null<MBlock>
		return v >= nv ? vpBlock[v - nv] : f.vals[v].op == Phi ? f.vals[v].block : null;

	inline function phiArgs(v:Int):Vector<Int>
		return v >= nv ? vpArgs[v - nv] : f.vals[v].args;

	// ---- the log

	function report() {
		var lines = [];
		for (k in 0...sites.length) {
			var r = find(k);
			var s = sites[k];
			var what = s.box > 0 ? "box" + s.box : s.tySym;
			var w = escaped[r] ? (whys[r] == null ? "?" : whys[r]) : "replaced";
			lines.push('escape: ${f.name}: $what: $w');
		}
		Sys.println(lines.join("\n"));
	}

	function failWhy(u:Null<MIns>):String {
		if (u == null) return "a use";
		var s = MFunc.opName(u.op);
		if (u.op == Call) s += " " + (u.sym == null ? "(indirect)" : u.sym);
		if (u.op == Store && u.c >= 0 && srcOf(u.c) >= 0)
			s += " (as a value" + (cellOf[u.id] > 0 ? ", into an untracked slot" : ", memory class " + u.mem) + ")";
		return s;
	}

	// ---- scalar replacement

	var pending:Array<{b:MBlock, at:Null<MIns>, i:MIns}> = [];
	var newPhis:Array<MIns> = [];
	var zeros:Map<Int, Int> = new Map();

	function newIns(op:Op, ty:MTy, b:MBlock, before:Null<MIns>):MIns {
		var x = new MIns(op, ty);
		x.id = f.vals.length;
		f.vals.push(x);
		x.block = b;
		x.pos = before != null ? before.pos : 0;
		pending.push({b: b, at: before, i: x});
		return x;
	}

	function zero(t:MTy):Int {
		var z = zeros.get(t);
		if (z != null) return z;
		var e = f.entry;
		var at:Null<MIns> = null;
		for (i in e.ins)
			if (i.op != Phi && i.op != Param) {
				at = i;
				break;
			}
		var x = newIns(t == F64 ? ConstF : Const, t, e, at);
		zeros.set(t, x.id);
		return x.id;
	}

	// replaces group g by variables (false: its accesses do not fit)
	function replace(g:Group):Bool {
		var box = sites[g.root].box;
		var phiStart = newPhis.length;
		// the variables: the accessed ranges, identical or disjoint (narrower
		// loads at a range's start read its low bytes; stores of zero define
		// the ranges they cover)
		var vars:Array<Var> = [];
		if (box == 0) {
			vars.push(new Var(-8, 4, I32));
			vars.push(new Var(Abi.HDR_TINDEX, 4, I32));
		} else
			vars.push(box == 1 ? new Var(0, 4, I32) : box == 2 ? new Var(0, 8, F64) : new Var(0, 8, I64));
		var nslots = sites[g.root].nslots;
		var order = [for (k in 0...g.accesses.length) k];
		// (wider first: a narrower load then finds its range)
		order.sort((a, b) -> {
			var sa = accSize(g.accesses[a]), sb = accSize(g.accesses[b]);
			sa != sb ? sb - sa : a - b;
		});
		var varOf = new Map<Int, Int>(); // access -> variable
		var zeroStores:Array<Int> = []; // (accesses)
		for (k in order) {
			var u = g.accesses[k], off = g.offs[k];
			if (u.op == Call) {
				varOf.set(u.id, 0);
				continue;
			}
			var size = u.size;
			var t = u.op == Load ? u.ty : f.vals[u.c].ty;
			if (off < -8 || off + size > 8 * nslots) return false;
			if (u.op == Store && isConst(u.c, 0)) {
				zeroStores.push(k);
				continue;
			}
			if (size != 1 && size != 2 && size != 4 && size != 8 || size == 8 && t == I32 || size < 8 && t != I32) return false;
			var v = -1;
			for (j in 0...vars.length) {
				var r = vars[j];
				if (r.off == off) {
					if (r.size == size) {
						v = j;
						if (r.ty != t) {
							if (size != 8) return false;
							r.ty = I64; // (doubles and words: words)
						}
					} else if (u.op == Load && size < r.size && r.ty != F64) v = j else return false;
				} else if (off < r.off + r.size && r.off < off + size) return false;
			}
			if (v < 0) {
				if (u.op == Load && size < 4) return false; // (a narrow load of nothing wider)
				v = vars.length;
				vars.push(new Var(off, size, t));
			}
			varOf.set(u.id, v);
		}
		// stores of zero: every range they cover
		var zeroVars = new Map<Int, Array<Int>>();
		for (k in zeroStores) {
			var u = g.accesses[k], off = g.offs[k];
			var vs = [];
			for (j in 0...vars.length) {
				var r = vars[j];
				if (r.off >= off && r.off + r.size <= off + u.size) vs.push(j);
				else if (r.off < off + u.size && off < r.off + r.size) return false;
			}
			zeroVars.set(u.id, vs);
		}
		// fields holding references stay in memory the collector sees, a slot
		// of the function's shadow-stack frame each (as SSA values a collection
		// would leave them pointing at the object's old place)
		var slotOf = MFunc.ints(vars.length, -1);
		var nrooted = 0;
		if (box == 0) {
			var s = sites[g.root];
			var refs = refSlots == null ? null : refSlots.get(s.tySym != null ? s.tySym : "#" + s.tyImm);
			for (j in 0...vars.length) {
				var r = vars[j];
				if (r.off < 0 || r.size != 8 || r.ty == F64) continue;
				if (refs == null) return false; // (a word that may be a reference)
				if (r.off & 7 == 0 && (r.off >> 3) < refs.length && refs[r.off >> 3]) {
					slotOf[j] = 0;
					nrooted++;
				}
			}
			if (nrooted > 0) {
				for (k in 0...g.accesses.length) {
					var v = varOf.get(g.accesses[k].id);
					if (v != null && slotOf[v] >= 0 && g.accesses[k].size != 8) return false;
				}
				if (!frameReady()) return false;
				for (j in 0...vars.length)
					if (slotOf[j] >= 0) slotOf[j] = frameSlot();
			}
		}
		// (a store of the frame slot)
		function slotStore(before:MIns, off:Int, v:Int) {
			var st = newIns(Store, Void, before.block, before);
			st.a = frameRoot;
			st.c = v;
			st.imm = off;
			st.imm2 = 1;
			st.size = 8;
			st.mem = Opt.MFrame;
		}
		for (u in g.accesses) {
			var v = varOf.get(u.id);
			if (v == null || slotOf[v] < 0) continue;
			// (the access is the slot's)
			u.a = frameRoot;
			u.b = -1;
			u.imm = slotOf[v];
			u.imm2 = 1;
			u.mem = Opt.MFrame;
			varOf.remove(u.id);
		}
		if (nrooted > 0) {
			for (s in g.sites)
				for (j in 0...vars.length)
					if (slotOf[j] >= 0) slotStore(s.defAt, slotOf[j], zero(I64));
			for (k in zeroStores) {
				var u = g.accesses[k];
				for (j in zeroVars.get(u.id))
					if (slotOf[j] >= 0) slotStore(u, slotOf[j], zero(I64));
			}
		}
		// the definitions: each site (zeros, the header; the boxed value),
		// before the instruction it counts from, and the stores
		var siteDef = new Map<Int, Site>();
		for (s in g.sites)
			siteDef.set(s.defAt.id, s);
		var n = vars.length;
		var blocks:Array<MBlock> = [];
		var seen = f.newMark();
		inline function touch(b:MBlock)
			if (b.mark != seen) {
				b.mark = seen;
				blocks.push(b);
			}
		for (s in g.sites)
			touch(s.block);
		for (u in g.accesses)
			touch(u.block);
		var stored = new Map<Int, Int>(); // store -> the value it gives its variable
		function storedValue(st:MIns, v:Int):Int {
			var r = stored.get(st.id);
			if (r != null) return r;
			var c = st.c;
			if (vars[v].ty == I64 && f.vals[c].ty == F64) {
				var x = newIns(FToBits, I64, st.block, st);
				x.a = c;
				c = x.id;
			}
			stored.set(st.id, c);
			return c;
		}
		function siteValue(s:Site, v:Int):Int {
			var r = vars[v];
			if (s.box > 0) return s.v.args[0];
			if (r.off == -8) return s.hdr.c;
			if (r.off == Abi.HDR_TINDEX) return s.ty.c;
			return zero(r.ty);
		}
		// what one instruction defines (cur: the variables' values)
		function define(i:MIns, cur:Vector<Int>) {
			var s = siteDef.get(i.id);
			if (s != null)
				for (v in 0...n)
					cur[v] = siteValue(s, v);
			if (i.op != Store) return;
			var zv = zeroVars.get(i.id);
			if (zv != null) {
				for (v in zv)
					cur[v] = zero(vars[v].ty);
				return;
			}
			var v = varOf.get(i.id);
			if (v != null) cur[v] = storedValue(i, v);
		}
		// the variables' values at the end of the blocks, then a reader each
		var endsOf = new Vector<Vector<Int>>(n);
		for (v in 0...n)
			endsOf[v] = MFunc.ints(nb, NONE);
		for (b in blocks) {
			var cur = MFunc.ints(n, NONE);
			for (i in b.ins)
				if (!i.dead) define(i, cur);
			for (v in 0...n)
				endsOf[v][b.id] = cur[v];
		}
		var readers = new Vector<Reader>(n);
		for (v in 0...n) {
			var ty = vars[v].ty;
			readers[v] = new Reader(f.entry, NONE, endsOf[v], MFunc.ints(nb, NOTSET), b -> {
				var phi = new MIns(Phi, ty);
				phi.id = f.vals.length;
				f.vals.push(phi);
				phi.block = b;
				var k = 0;
				while (k < b.ins.length && b.ins[k].op == Phi)
					k++;
				b.ins.insert(k, phi);
				newPhis.push(phi);
				phi.id;
			}, (p, args) -> f.vals[p].args = args);
		}
		// the reads
		for (b in blocks) {
			var cur = MFunc.ints(n, NONE);
			for (i in b.ins.copy()) {
				if (i.dead) continue;
				define(i, cur);
				if (i.op != Load && i.op != Call) continue;
				var v = varOf.get(i.id);
				if (v == null) continue;
				var x = cur[v] != NONE ? cur[v] : readers[v].readEntry(b);
				if (x == NONE) x = zero(vars[v].ty);
				read(i, x, vars[v]);
			}
		}
		for (r in readers)
			r.finish();
		// (an entry read nothing defines: zero; never on a path from a site)
		for (j in phiStart...newPhis.length) {
			var p = newPhis[j];
			for (k in 0...p.args.length)
				if (p.args[k] == NONE) p.args[k] = zero(p.ty);
		}
		// the stores go; the cells keep null; the barrier and the tests know
		// the object is young and not null
		for (u in g.accesses)
			if (u.op == Store && !(u.a == frameRoot && u.mem == Opt.MFrame)) u.dead = true;
		var z64 = g.cellStores.length > 0 ? zero(I64) : -1;
		for (u in g.cellStores)
			u.c = z64;
		for (u in g.barriers)
			u.dead = true;
		for (u in g.young)
			toConst(u, 1);
		for (u in g.nulls)
			toConst(u, u.imm == CEq ? 0 : 1);
		for (u in g.derived)
			u.dead = true;
		for (x in g.aliases)
			f.vals[x].dead = true;
		// the allocations go
		for (s in g.sites) {
			if (s.box > 0) {
				s.v.dead = true;
				continue;
			}
			s.tls.dead = true;
			s.hdr.dead = true;
			s.ty.dead = true;
			jumpTo(s.head, s.head.term(), s.fast);
		}
		removed += g.sites.length;
		return true;
	}

	// the function's shadow-stack frame (pushed in its entry block): its
	// base (an rt_sp value), the push's size, made larger by frameSlot
	var frameRoot = -1;
	var frameTop:Null<MIns> = null;
	var frameBytes = 0;

	function frameReady():Bool {
		if (frameTop != null) return true;
		for (i in f.entry.ins)
			if (!i.dead && i.op == TlsStore && i.sym == "rt_sp") {
				var a = f.vals[i.a];
				if (a.op != Add) return false;
				var r = f.vals[a.a], c = constOf(a.b);
				if (r.op != TlsLoad || r.sym != "rt_sp" || r.block != f.entry || c == null || c.sym != null) return false;
				frameRoot = r.id;
				frameTop = a;
				frameBytes = c.imm;
				return true;
			}
		return false;
	}

	// a new slot of the frame (its offset)
	function frameSlot():Int {
		var off = frameBytes;
		frameBytes += 8;
		var k = newIns(Const, I64, f.entry, frameTop);
		k.imm = frameBytes;
		frameTop.b = k.id;
		return off;
	}

	static inline function accSize(u:MIns):Int
		return u.op == Call ? 8 : u.size;

	// load or unbox i reads x, the value of variable r
	function read(i:MIns, x:Int, r:Var) {
		var b = i.block;
		if (i.op == Call) {
			var conv = i.sym == "hx_unbox_float" && r.ty == I32;
			i.op = conv ? I2F : Copy;
			i.a = x;
			i.sym = null;
			i.args = vector();
			i.argTys = vector();
			i.cCall = false;
			i.cSizes = vector();
			i.cGroups = vector();
			i.structRet = false;
			i.cRet = vector();
			i.keepsFrame = false;
			i.noReturn = false;
			return;
		}
		var size = i.size, signed = i.signed, ty = i.ty;
		i.b = -1;
		i.c = -1;
		i.imm = 0;
		i.imm2 = 0;
		i.size = 0;
		i.signed = false;
		i.mem = 0;
		if (r.off == Abi.HDR_TINDEX) {
			// (the 16-bit type index: the whole constant, as every comparison takes it)
			i.op = Copy;
			i.a = x;
			return;
		}
		if (ty == F64 && r.ty == I64) {
			i.op = BitsToF;
			i.a = x;
		} else if (ty == I64 && r.ty == F64) {
			i.op = FToBits;
			i.a = x;
		} else if (ty == I32 && r.ty == I64) {
			if (size == 4) {
				i.op = Trunc;
				i.a = x;
			} else {
				var t = newIns(Trunc, I32, b, i);
				t.a = x;
				narrow(i, t.id, size, signed);
			}
		} else if (size < 4 && r.size == 4)
			narrow(i, x, size, signed)
		else {
			i.op = Copy;
			i.a = x;
		}
	}

	// i: the low size bytes of the 32-bit x
	function narrow(i:MIns, x:Int, size:Int, signed:Bool) {
		var b = i.block;
		var k = newIns(Const, I32, b, i);
		if (signed) {
			var bits = 32 - 8 * size;
			k.imm = bits;
			var sh = newIns(Shl, I32, b, i);
			sh.a = x;
			sh.b = k.id;
			i.op = Sar;
			i.a = sh.id;
			i.b = k.id;
		} else {
			k.imm = size == 1 ? 0xFF : 0xFFFF;
			i.op = And;
			i.a = x;
			i.b = k.id;
		}
	}

	// the new instructions in place, the dead ones out
	function sweep() {
		for (p in pending) {
			var ins = p.b.ins;
			var k = p.at == null ? -1 : ins.indexOf(p.at);
			if (k < 0) {
				k = ins.length;
				if (k > 0 && ins[k - 1].isTerm()) k--;
			}
			ins.insert(k, p.i);
		}
		pending = [];
		for (b in f.blocks) {
			var ins = b.ins, k = 0;
			for (i in ins)
				if (!i.dead) ins[k++] = i;
			if (k < ins.length) ins.resize(k);
		}
	}

	// the phis made whose operands are one value (or the phi) are copies of it
	function trivialPhis() {
		var changed = true;
		while (changed) {
			changed = false;
			for (p in newPhis) {
				if (p.op != Phi || p.dead) continue;
				var same = -1, trivial = true;
				for (a in p.args) {
					var x = a;
					while (f.vals[x].op == Copy && f.vals[x].a >= 0)
						x = f.vals[x].a;
					if (x == p.id || x == same) continue;
					if (same >= 0) {
						trivial = false;
						break;
					}
					same = x;
				}
				if (trivial && same >= 0) {
					p.op = Copy;
					p.a = same;
					p.args = vector();
					changed = true;
				}
			}
		}
	}
}

private class Site {
	public var v:MIns; // the object (the phi) or the box (the call)
	public var block:MBlock;
	public var box = 0; // 1 Int, 2 Float, 3 Int64 (0: an object)
	public var key:Null<String>; // the layout: a group's sites agree (layout())
	public var hdrImm = 0; // (an object's header words)
	public var tySym:Null<String>;
	public var tyImm = 0;
	public var defAt:MIns; // the instruction its values are defined before
	public var head:MBlock;
	public var fast:MBlock;
	public var tls:MIns; // the bump of rt_young_ptr
	public var hdr:MIns; // the header's stores
	public var ty:MIns;
	public var nslots = 1;

	public function new(v, block) {
		this.v = v;
		this.block = block;
	}

	public function layout():String {
		if (key == null) key = "o" + hdrImm + ":" + (tySym == null ? "" : tySym) + ":" + tyImm;
		return key;
	}
}

private class Group {
	public var root:Int;
	public var sites:Array<Site> = [];
	public var aliases:Array<Int> = [];
	public var accesses:Array<MIns> = []; // loads and stores (at offs), unboxings
	public var offs:Array<Int> = [];
	public var bases:Array<Int> = []; // the alias each access goes through
	public var cellStores:Array<MIns> = [];
	public var derived:Array<MIns> = []; // addresses into the object, barrier tests
	public var young:Array<MIns> = [];
	public var nulls:Array<MIns> = [];
	public var barriers:Array<MIns> = [];

	public function new(root)
		this.root = root;

	public function access(u:MIns, x:Int, off:Int) {
		accesses.push(u);
		offs.push(off);
		bases.push(x);
	}
}

private class Var {
	public var off:Int;
	public var size:Int;
	public var ty:MTy;

	public function new(off, size, ty) {
		this.off = off;
		this.size = size;
		this.ty = ty;
	}
}

// a variable's value at block entries, on demand (Braun et al.): the
// definition at the end of a block (ends, by block number: NONE), else a
// phi where predecessors meet (made by mkPhi, its operands set by setArgs in
// finish), else the entry's value; iterative (no recursion along long
// paths); memo: by block number, NOTSET (reset puts it back)
private class Reader {
	public var ends:Vector<Int>;
	var memo:Vector<Int>;
	var touched:Array<Int> = [];
	var entry:MBlock;
	var undef:Int;
	var mkPhi:MBlock->Int;
	var setArgs:(Int, Vector<Int>) -> Void;
	var pendV:Array<Int> = [];
	var pendB:Array<MBlock> = [];
	var npend = 0;

	static inline var NONE = -3;
	static inline var NOTSET = -4;

	public function new(entry, undef, ends, memo, mkPhi, setArgs) {
		this.entry = entry;
		this.undef = undef;
		this.ends = ends;
		this.memo = memo;
		this.mkPhi = mkPhi;
		this.setArgs = setArgs;
	}

	inline function remember(b:MBlock, v:Int) {
		memo[b.id] = v;
		touched.push(b.id);
	}

	public inline function readEnd(b:MBlock):Int {
		var d = ends[b.id];
		return d != NONE ? d : readEntry(b);
	}

	public function readEntry(b:MBlock):Int {
		var chain:Array<MBlock> = [];
		var r = undef;
		var n = 0;
		while (true) {
			var m = memo[b.id];
			if (m != NOTSET) {
				r = m;
				break;
			}
			if (b == entry || b.preds.length == 0 || n++ > 1000000) {
				r = undef;
				remember(b, r);
				break;
			}
			if (b.preds.length == 1) {
				chain.push(b);
				var p = b.preds[0];
				var d = ends[p.id];
				if (d != NONE) {
					r = d;
					break;
				}
				b = p;
				continue;
			}
			r = mkPhi(b);
			remember(b, r);
			pendV[npend] = r;
			pendB[npend++] = b;
			break;
		}
		for (x in chain)
			remember(x, r);
		return r;
	}

	public function finish() {
		while (npend > 0) {
			npend--;
			var v = pendV[npend], b = pendB[npend];
			var args = new Vector<Int>(b.preds.length);
			for (k in 0...args.length)
				args[k] = readEnd(b.preds[k]);
			setArgs(v, args);
		}
	}

	public function reset() {
		for (k in touched)
			memo[k] = NOTSET;
		touched = [];
	}
}
