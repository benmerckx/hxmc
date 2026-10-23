package hxmc;

import haxe.ds.Vector;
import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.Ssa;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Escape analysis with scalar replacement, on object-level Mir (after
// inlining, before MemLower): an allocation that never leaves its function
// is replaced by its fields in SSA values, and is not made at all.
//
// The allocations are New's (class instances, anonymous objects, enum
// values, closures, the boxes of captured variables) and Box's (an Int,
// Float or Int64 as a Dynamic). An allocation's aliases are its value, its
// copies, phis of aliases only (a cold site's continuation phi among them:
// the same object after the GC point), and what is read back from a
// shadow-stack slot it was stored into ("cells": variables whose stores
// reach their loads; a collection moves objects but keeps what a slot
// refers to). Allocations that meet at a phi form a group, replaced
// together when their layouts agree: the group's fields are one set of
// variables, which is right only when every use of an alias is a use of
// the group's latest instance (checked: the alias's instance is the group's
// reaching allocation at the use; an object's allocation counts from its
// first use, so its constructor's arguments may still read the previous
// one). An alias may have its fields read and written (GetField, SetField,
// InitField), be tested against null (NullCheck, a comparison), be given to
// a cold site's GC point (which keeps it on the shadow stack across its slow
// path), be stored into a cell and, for a box, be unboxed; anything else (a
// call, a return, a store into the heap or a global, a phi with another
// value, an identity comparison) is an escape, and the group stays as it
// is. An object stored into another one's field escapes too (one level of
// objects; again after a replacement, the field being a frame slot then).
//
// Before that, what is known of any alias (escaping or not) folds: its type
// tests (TypeTest, EnumTag), its null tests, an anonymous object's
// structural accesses (AnonGet, AnonTest: its fields are known). A screen
// keeps the analysis to the allocations that may stay in the function or
// have such tests.
class Escape {
	static inline var EMPTY = -1; // lattice: no allocation seen (yet)
	static inline var TOP = -2; // lattice: anything else, or several groups
	static inline var UNDEF = -2; // abstract value: no store reaches (the variable's entry)
	static inline var NONE = SsaReader.NONE; // no definition in the block
	static inline var NOTSET = SsaReader.NOTSET;

	public static var on = Sys.getEnv("HXMC_ESCAPE") != "0";

	// (debugging: HXMC_ESCAPE_HASH=<lo>-<hi>, the functions whose names hash
	// to lo...hi of 0...1024 only; HXMC_ESCAPE_NO=<parts>, parts off:
	// closures, frames, again, boxes, replace, screen, anon)
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

	// per type index, which slots hold references (the Driver sets it; read
	// only): Mem.alloc's objects, whose words are read and written by
	// hxmc.unsafe's loads and stores, keep those on the shadow stack
	public static var refSlots:Null<Map<Int, Vector<Bool>>>;

	// (HXMC_ESCAPE_LOG=1) what happens to each allocation that is analyzed
	static var log = Sys.getEnv("HXMC_ESCAPE_LOG") == "1";

	var f:MFunc;

	public var removed = 0; // allocation sites replaced
	public var folds = 0; // tests folded on known objects

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
	// cells: shadow-stack slots at constant offsets
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

	// (HXMC_ESCAPE_DUMP=<function symbol>: its object-level Mir before and after)
	static var dumpName = Sys.getEnv("HXMC_ESCAPE_DUMP");

	public function run() {
		if (f.name == dumpName) Sys.println("escape: before\n" + f.dump());
		go();
		if (f.name == dumpName) Sys.println("escape: after\n" + f.dump());
	}

	function go() {
		if (f.allocs == 0 || !allowed(f.name)) return;
		f.edited();
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
		Ssa.trivialPhis(f.vals, newPhis);
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

	// The calls of f through closures whose function is known (a closure made
	// here, possibly kept in a shadow-stack slot that holds only closures of
	// that function) become direct calls of it (sym: its symbol), returned
	// when ok says it may be inlined and the closure may then be replaced (the
	// Driver inlines them, then the closure is an object like any other).
	public static function closureCalls(f:MFunc, ok:FuncInfo->Bool, sym:FuncInfo->String):Array<{call:MIns, fn:FuncInfo}> {
		var r = [];
		var calls = [];
		for (b in f.blocks)
			for (i in b.ins)
				if (!i.dead && i.op == ClosureCall) calls.push(i);
		if (calls.length == 0) return r;
		var e = new Escape(f);
		var nv = f.vals.length;
		var fn = new Vector<Null<FuncInfo>>(nv); // values that are closures of a known function
		var any = false;
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case New if (i.info.lambda != null):
						fn[i.id] = i.info.lambda.fn;
						any = true;
					case Phi:
						fn[i.id] = sameFn(fn, i);
					case Copy:
						fn[i.id] = fn[i.a];
					case _:
				}
			}
		if (!any) return r;
		// (slots that only ever hold closures of one function: "" several)
		var slots = new Map<Int, Null<FuncInfo>>();
		var mixed = new Map<Int, Bool>();
		for (b in f.blocks)
			for (i in b.ins)
				if (!i.dead && i.op == Store) {
					var k = e.slotKey(i);
					if (k < 0) continue;
					var s = fn[i.c];
					if (s == null || slots.exists(k) && slots.get(k) != s) mixed.set(k, true);
					slots.set(k, s);
				}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Load if (i.ty == I64 && fn[i.id] == null):
						var k = e.slotKey(i);
						if (k >= 0 && slots.exists(k) && !mixed.exists(k)) fn[i.id] = slots.get(k);
					case Copy if (fn[i.id] == null):
						fn[i.id] = fn[i.a];
					case Phi if (fn[i.id] == null):
						fn[i.id] = sameFn(fn, i);
					case _:
				}
			}
		for (c in calls) {
			var g = fn[c.args[0]];
			if (g == null) continue;
			// (a direct call of the closure's function, the closure first: as MirBuild's)
			c.op = Call;
			c.sym = sym(g);
			c.a = -1;
			c.argTys = g.args.mapToVector(a -> MirBuild.mty(a.ty) == Void ? I32 : MirBuild.mty(a.ty));
			c.info = null;
			if (ok(g)) r.push({call: c, fn: g});
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
	static function sameFn(fn:Vector<Null<FuncInfo>>, i:MIns):Null<FuncInfo> {
		var s:Null<FuncInfo> = null;
		for (a in i.args) {
			if (a == i.id) continue;
			var x = fn[a];
			if (x == null || s != null && s != x) return null;
			s = x;
		}
		return s;
	}

	// ---- allocation sites

	// an anonymous structure's field's slot (WasmGC: by its index, as MirBuild's)
	function shapeLoc(s:hxmc.ir.Ir.ShapeInfo, at:Int):Int
		return f.gc ? (s.fields[at].ty.match(TI32 | TBool) ? 2 * at : at) : s.locs[at];

	// what an allocation makes, by name (WasmGC's sites: no type indices)
	static function gcKey(o:OInfo):String
		return o.cls != null ? o.cls.name : o.ctor != null ? o.ctor.en.name + "." + o.ctor.name : o.lambda != null ? "lambda" + o.lambda.id : o.shape != null ? "shape"
			+ [for (x in o.shape.fields) x.name].join(",") : hxmc.ir.Ir.repr(o.t);

	// the site an instruction makes (null: none)
	function siteAt(i:MIns):Null<Site> {
		switch i.op {
			case New:
				var o = i.info;
				// (not an empty Array: the runtime takes it for any growth)
				if (o.name == OInfo.NEW_ARRAY || o.tindex == Abi.T_ARRAY) return null;
				var s = new Site(i, i.block);
				s.raw = o.name == OInfo.NEW_RAW;
				// (its values are defined where it is first used: what its
				// continuation computes before, its constructor's arguments, may
				// read the previous instance of its group)
				var j = o.cont;
				var after = false;
				if (j != null && j.preds.length == 1 && j.preds[0] == i.block) {
					s.block = j;
					after = true;
				} else j = i.block;
				s.defAt = j.term();
				for (u in j.ins) {
					if (u == i) after = true;
					if (!after || u == i || u.dead || u.op == Phi) continue;
					if (u.a == i.id || u.b == i.id || u.c == i.id || u.args.indexOf(i.id) >= 0) {
						s.defAt = u;
						break;
					}
				}
				if (s.defAt == null) return null;
				// (WasmGC: no type indices, the class, constructor, closure or shape by name)
				s.key = o.name + ":" + (f.gc ? gcKey(o) : "" + o.tindex) + ":" + o.n;
				return s;
			case Box if (part("boxes")):
				var k = switch i.info.t {
					case TI32: 1;
					case TF64: 2;
					case TI64: 3;
					case _: 0;
				};
				if (k == 0) return null;
				var s = new Site(i, i.block);
				s.defAt = i;
				s.box = k;
				s.key = "box" + k;
				return s;
			case _:
				return null;
		}
	}

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
						var e = NONE;
						for (a in i.args)
							if (a != i.id) e = e == NONE || e == exact[a] ? exact[a] : -1;
						if (e >= 0) exact[i.id] = e;
						der[i.id] = phiDer(i);
					case Copy:
						der[i.id] = der[i.a];
						exact[i.id] = exact[i.a];
					case New | Box:
						s = siteAt(i);
					case _:
				}
				if (s != null) {
					der[i.id] = exact[i.id] = all.length;
					uf.push(all.length);
					all.push(s);
				}
			}
		if (all.length == 0) return false;
		// (what is read back from shadow-stack slots they were stored into)
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
		var tests:Array<MIns> = [];
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Phi if (der[i.id] == -1):
						der[i.id] = phiDer(i);
					case Copy if (der[i.id] == -1):
						der[i.id] = der[i.a];
					case TypeTest | EnumTag | NullCheck | AnonGet | AnonTest if (exact[i.a] >= 0):
						tests.push(i);
					case Cmp if ((i.imm == CEq || i.imm == CNe) && (exact[i.a] >= 0 && isConst(i.b, 0) || exact[i.b] >= 0 && isConst(i.a, 0))):
						tests.push(i);
					case _ if (b.cold):
					case Call | VirtualCall | ClosureCall | AnonCall if (ignore == null || !ignore.exists(i.id)):
						if (isDer(i.a)) markSure(i.a);
						for (a in i.args)
							if (isDer(a)) markSure(a);
					case Ret | TlsStore if (isDer(i.a)):
						markSure(i.a);
					case Store if (isDer(i.c) && (i.mem == Opt.MField || i.mem == Opt.MElem || i.mem == Opt.MGlobal || i.mem == Opt.MInit)):
						markSure(i.c);
					case SetField | InitField | ArrayInit | NArrayInit | AnonStore if (isDer(i.b)):
						markSure(i.b);
					case ArraySet | ArrayPush | NArraySet | NArrayDyn | RefStore if (isDer(i.c)):
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
		for (i in tests) {
			var x = i.op == Cmp ? (exact[i.a] >= 0 ? i.a : i.b) : i.a;
			var k = exact[x];
			if (sure[root(k)] && foldOn(i, all[k], x)) n++;
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

	// a load's or store's slot when its address is rt_sp plus a constant (-1: other memory)
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

	// ---- what is known of an object

	// folds test u of x, an alias of site s whose layout is known (false:
	// nothing to fold)
	function foldOn(u:MIns, s:Site, x:Int):Bool {
		var o = s.v.info;
		switch u.op {
			case Cmp:
				toConst(u, u.imm == CEq ? 0 : 1);
				return true;
			case NullCheck:
				u.dead = true;
				return true;
			case TypeTest if (s.box == 0):
				// (the classes' type indices are in their preorder: TYSPAN_)
				var c = u.info.cls, k = o.cls;
				toConst(u, k != null && k.id >= c.id && k.id <= c.lastDescendant ? 1 : 0);
				return true;
			case EnumTag if (o.ctor != null):
				toConst(u, o.ctor.tag);
				return true;
			case AnonGet if (o.shape != null && part("anon")):
				var at = anonField(o.shape, u.info.name, u.info.t);
				if (at < 0) return false;
				var t = o.shape.fields[at].ty;
				var i = new OInfo();
				i.t = t;
				i.loc = shapeLoc(o.shape, at);
				i.shape = o.shape;
				u.op = GetField;
				u.info = i;
				return true;
			case AnonTest if (o.shape != null && part("anon")):
				var at = anonField(o.shape, u.info.name, u.info.t);
				var hit = u.targets[0];
				if (at >= 0) {
					// (the store: AnonStore in the hit block, of this test)
					for (st in hit.ins)
						if (st.op == AnonStore && st.c == u.id) {
							var i = new OInfo();
							i.t = o.shape.fields[at].ty;
							i.loc = shapeLoc(o.shape, at);
							i.shape = o.shape;
							i.cont = st.info.cont;
							st.op = SetField;
							st.c = -1;
							st.info = i;
						}
				}
				jumpTo(u.block, u, at >= 0 ? hit : u.targets[1]);
				return true;
			case _:
				return false;
		}
	}

	// the field of shape s that a structural access of the name, of type t,
	// finds in place (an inline cache's slot of the field's kind: MemLower.kindMatch;
	// -1: none, its slow path)
	static function anonField(s:ShapeInfo, name:String, t:Ty):Int {
		var k = s.slot(name) - 1;
		if (k < 0) return -1;
		var ft = s.fields[k].ty;
		var ok = switch t {
			case TI32 | TBool: ft.match(TI32 | TBool);
			case TF64: ft == TF64;
			case TI64: ft == TI64;
			case _: ft.match(TRef(_));
		};
		return ok ? k : -1;
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
			if (sites[r].key != sites[k].key) {
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
		var seen = new Vector<Int>(users.length), gen = 0;
		while (top > 0) {
			var p = work[--top];
			if (repl[p] >= 0 || !trivial(p)) continue;
			// (its users, through copies, cell loads and phis that collapsed
			// already, resolve further)
			next[nt++] = p;
			gen++;
			while (nt > 0) {
				var us = users[next[--nt]];
				if (us != null)
					for (y in us) {
						if (seen[y] == gen) continue;
						seen[y] = gen;
						if ((y >= nv || f.vals[y].op == Phi) && repl[y] < 0) work[top++] = y else next[nt++] = y;
					}
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

	// the accesses of one shadow-stack frame (an rt_sp value), at constant
	// offsets; an address that leaves (but as a call's argument or a cold
	// site's frame, whose slots the runtime handles) keeps the whole frame
	// untracked
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
					// (the frame of a cold site's spill slots and of an array store's
					// slot: the spill slots are no cells; a rooted array's slot is
					// given to the runtime)
					case New | NewDyn | ArraySet | ArrayPush | NewNArray | NArrayDyn if (u.a != v && u.b != v && u.c != v):
						if (u.info.rootSlot >= 0) untrack.push(off + 8 * u.info.rootSlot);
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
		var rd = new SsaReader(f.entry, UNDEF, ends, memo, newVp, setVpArgs);
		for (l in early)
			reach[l.id] = rd.readEntry(l.block);
		rd.finish();
		rd.reset();
		for (b in blocks)
			ends[b.id] = NONE;
		for (k in first...vpBlock.length)
			cellVps[c].push(nv + k);
	}

	// ---- folding on known objects

	// the layout of an alias is its group's: what is known of it folds,
	// then comparisons of equal constants, and branches and switches on
	// constants
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
					case TypeTest | EnumTag | NullCheck | AnonGet | AnonTest if (u.a == x):
						if (foldOn(u, site, x)) n++;
					case Cmp if ((u.imm == CEq || u.imm == CNe) && (u.a == x && isConst(u.b, 0) || u.b == x && isConst(u.a, 0))):
						if (foldOn(u, site, x)) n++;
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
		i.info = null;
		i.args = vector();
	}

	function constFold() {
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				switch i.op {
					case Cmp if (i.imm == CEq || i.imm == CNe):
						var x = constOf(i.a), y = constOf(i.b);
						if (x == null || y == null || x.ty != y.ty) continue;
						var eq = if (x.sym == y.sym && x.imm == y.imm && x.imm2 == y.imm2) 1 else if (x.sym == null && y.sym == null) 0 else -1;
						if (eq >= 0) toConst(i, i.imm == CEq ? eq : 1 - eq);
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
		t.b = -1;
		t.info = null;
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
			if (!uses1(g, x)) escape(s, failWhy(lastFail));
		}
		// the instance used is the group's latest
		for (g in acc) {
			if (g == null || escaped[g.root]) continue;
			for (k in 0...g.accesses.length)
				if (!latest(g, g.bases[k], g.accesses[k])) {
					escape(g.root, "not the latest instance" + (log ? " (" + MFunc.insString(g.accesses[k]) + ")" : ""));
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

	// the uses of alias x (false: an escape)
	function uses1(g:Group, x:Int):Bool {
		var box = sites[g.root].box, raw = sites[g.root].raw;
		for (q in useStart[x]...useStart[x + 1]) {
			var u = useList[q];
			if (u.dead) continue;
			lastFail = u;
			switch u.op {
				case Copy:
				case Phi:
					var s = srcOf(u.id);
					if (s < 0 || find(s) != g.root) return false;
				case GetField if (box == 0 && !raw):
					g.access(u, x);
				case SetField | InitField if (box == 0 && !raw && u.a == x && u.b != x):
					var c = srcOf(u.b);
					if (c >= 0) escape(c, "stored into an object"); // (one level)
					g.access(u, x);
				// (Mem.alloc's object: hxmc.unsafe's loads and stores at constant offsets)
				case Load if (raw && u.a == x && u.b < 0):
					g.access(u, x);
				case Store if (raw && u.a == x && u.b < 0 && u.c != x):
					var c = srcOf(u.c);
					if (c >= 0) escape(c, "stored into an object");
					g.access(u, x);
				case RefStore if (raw && u.a == x && u.b != x && u.c != x && constOf(u.b) != null && constOf(u.b).sym == null):
					var c = srcOf(u.c);
					if (c >= 0) escape(c, "stored into an object");
					g.access(u, x);
				case Store if (u.c == x && u.a != x && u.b != x && cellOf[u.id] > 0 && cellTracked[cellOf[u.id] - 1]):
					g.cellStores.push(u);
				case NullCheck:
					g.nulls.push(u);
				case Cmp if ((u.imm == CEq || u.imm == CNe) && (u.a == x && isConst(u.b, 0) || u.b == x && isConst(u.a, 0))):
					g.nulls.push(u);
				case Unbox if (box > 0 && unboxOk(box, u.info.t)):
					g.access(u, x);
				case New | NewDyn | ArraySet | ArrayPush | NewNArray | NArrayDyn if (u.info.cold && u.a != x && u.b != x && u.c != x):
					// (a cold site keeps it on the shadow stack: no need once it is not made)
					var k = u.args.indexOf(x);
					if (k < 0 || k >= u.info.nspill) return false;
					g.spills.push(u);
				case _:
					return false;
			}
		}
		return true;
	}

	static function unboxOk(box:Int, t:Ty):Bool
		return switch t {
			case TI32: box == 1;
			case TF64: box == 1 || box == 2;
			case TI64: box == 3;
			case _: false;
		};

	// ---- the latest instance

	var curReaders:Map<Int, SsaReader> = new Map();

	// where u uses alias x: the group's reaching allocation is x's instance
	function latest(g:Group, x:Int, u:MIns):Bool {
		var rd = curReaders.get(g.root);
		if (rd == null) {
			var defs = MFunc.ints(nb, NONE);
			for (k in 0...sites.length)
				if (find(k) == g.root) defs[sites[k].block.id] = sites[k].v.id;
			rd = new SsaReader(f.entry, UNDEF, defs, MFunc.ints(nb, NOTSET), newVp, setVpArgs);
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
			var w = escaped[r] ? (whys[r] == null ? "?" : whys[r]) : "replaced";
			lines.push('escape: ${f.name}: ${s.what()}: $w');
		}
		Sys.println(lines.join("\n"));
	}

	function failWhy(u:Null<MIns>):String {
		if (u == null) return "a use";
		var s = MFunc.opName(u.op);
		if (u.op == Call) s += " " + (u.sym == null ? "(indirect)" : u.sym);
		if (u.op == Store && u.c >= 0 && srcOf(u.c) >= 0)
			s += " (as a value" + (cellOf[u.id] > 0 ? ", into an untracked slot" : ", memory class " + u.mem) + ")";
		if ((u.op == SetField || u.op == InitField) && u.b >= 0 && srcOf(u.b) >= 0) s += " (as a value)";
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

	// an access's bytes in the object (a field's from its static part, a
	// load's or store's of Mem.alloc's object from its displacement), its
	// type, the value it stores (-1: a read)
	function accOff(u:MIns):Int
		return switch u.op {
			case GetField | SetField | InitField: u.info.t.match(TI32 | TBool | TU8) ? 4 * u.info.loc : 8 * u.info.loc;
			case RefStore: constOf(u.b).imm;
			case Unbox: 0;
			case _: u.imm;
		};

	function accSize(u:MIns):Int
		return switch u.op {
			case GetField | SetField | InitField: u.info.t.match(TI32 | TBool | TU8) ? 4 : u.info.t == TVoid ? 0 : 8;
			case RefStore | Unbox: 8;
			case _: u.size;
		};

	function accTy(u:MIns):MTy
		return switch u.op {
			case GetField | SetField | InitField: MirBuild.mty(u.info.t);
			case RefStore: I64;
			case Store: f.vals[u.c].ty;
			case _: u.ty;
		};

	static function accValue(u:MIns):Int
		return switch u.op {
			case SetField | InitField: u.b;
			case Store | RefStore: u.c;
			case _: -1;
		};

	// replaces group g by variables (false: its accesses do not fit)
	function replace(g:Group):Bool {
		var site = sites[g.root];
		var box = site.box;
		var phiStart = newPhis.length;
		// the variables: the ranges accessed, identical or disjoint (narrower
		// loads at a range's start read its low bytes); stores of zero (and an
		// enum value's cleared words: InitField's next) define the ranges
		// they cover
		var vars:Array<Var> = [];
		if (box > 0) vars.push(box == 1 ? new Var(0, 4, I32) : box == 2 ? new Var(0, 8, F64) : new Var(0, 8, I64));
		var nslots = site.v.info.n;
		var refs = site.raw && refSlots != null ? refSlots.get(site.v.info.tindex) : null;
		var order = [for (k in 0...g.accesses.length) k];
		// (wider first: a narrower load then finds its range)
		order.sort((a, b) -> {
			var sa = accSize(g.accesses[a]), sb = accSize(g.accesses[b]);
			sa != sb ? sb - sa : a - b;
		});
		var varOf = new Map<Int, Int>(); // access -> variable
		var zeroStores:Array<{u:MIns, off:Int, size:Int}> = [];
		for (k in order) {
			var u = g.accesses[k];
			if (u.op == Unbox) {
				varOf.set(u.id, 0);
				continue;
			}
			if (u.op == InitField && u.info.next >= 0) zeroStores.push({u: u, off: 8 * u.info.next, size: 8});
			var off = accOff(u), size = accSize(u), t = accTy(u);
			if (size == 0) continue;
			if (off < 0 || off + size > 8 * nslots) return false;
			var value = accValue(u);
			if (value >= 0 && isConst(value, 0)) {
				zeroStores.push({u: u, off: off, size: size});
				continue;
			}
			if (size != 1 && size != 2 && size != 4 && size != 8 || size == 8 && t == I32 || size < 8 && t != I32) return false;
			// (a reference: its field's type, a barriered store, or the type's
			// pointer map for Mem.alloc's object)
			var ref = switch u.op {
				case GetField | SetField | InitField: u.info.t.match(TRef(_));
				case RefStore: true;
				case _:
					if (size == 8 && t != F64 && (refs == null || off & 7 != 0)) return false; // (a word that may be a reference)
					size == 8 && t != F64 && (off >> 3) < refs.length && refs[off >> 3];
			};
			var v = -1;
			for (j in 0...vars.length) {
				var r = vars[j];
				if (r.off == off) {
					if (r.size == size) {
						v = j;
						if (r.ty != t) {
							if (size != 8 || r.ref || ref) return false;
							r.ty = I64; // (doubles and words: words)
						}
						if (r.ref != ref) return false;
					} else if (u.op == Load && size < r.size && r.ty != F64 && !r.ref) v = j else return false;
				} else if (off < r.off + r.size && r.off < off + size) return false;
			}
			if (v < 0) {
				if (u.op == Load && size < 4) return false; // (a narrow load of nothing wider)
				v = vars.length;
				var r = new Var(off, size, t);
				r.ref = ref;
				vars.push(r);
			}
			varOf.set(u.id, v);
		}
		// stores of zero: every range they cover
		var zeroVars = new Map<Int, Array<Int>>();
		for (z in zeroStores) {
			var vs = zeroVars.get(z.u.id);
			if (vs == null) zeroVars.set(z.u.id, vs = []);
			for (j in 0...vars.length) {
				var r = vars[j];
				if (r.off >= z.off && r.off + r.size <= z.off + z.size) vs.push(j);
				else if (r.off < z.off + z.size && z.off < r.off + r.size) return false;
			}
		}
		// fields holding references stay in memory the collector sees, a slot
		// of the function's shadow-stack frame each (as SSA values a collection
		// would leave them pointing at the object's old place)
		var slotOf = MFunc.ints(vars.length, -1);
		var nrooted = 0;
		// (WasmGC: the engine's collector sees SSA values)
		for (j in 0...vars.length)
			if (vars[j].ref && !f.gc) {
				slotOf[j] = 0;
				nrooted++;
			}
		if (nrooted > 0) {
			for (u in g.accesses) {
				var v = varOf.get(u.id);
				if (v != null && slotOf[v] >= 0 && accSize(u) != 8) return false;
			}
			if (!frameReady()) return false;
			for (j in 0...vars.length)
				if (slotOf[j] >= 0) slotOf[j] = frameSlot();
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
		var rooted:Array<MIns> = [];
		for (u in g.accesses) {
			var v = varOf.get(u.id);
			if (v == null || slotOf[v] < 0) continue;
			// (the access is the slot's)
			var value = accValue(u);
			if (value < 0) {
				u.op = Load;
				u.ty = I64;
			} else {
				u.op = Store;
				u.c = value;
			}
			u.a = frameRoot;
			u.b = -1;
			u.imm = slotOf[v];
			u.imm2 = 1;
			u.size = 8;
			u.signed = false;
			u.mem = Opt.MFrame;
			u.info = null;
			varOf.remove(u.id);
			rooted.push(u);
		}
		if (nrooted > 0) {
			for (s in g.sites)
				for (j in 0...vars.length)
					if (slotOf[j] >= 0) slotStore(s.defAt, slotOf[j], zero(I64));
			for (z in zeroStores)
				for (j in zeroVars.get(z.u.id))
					if (slotOf[j] >= 0) slotStore(z.u, slotOf[j], zero(I64));
		}
		// the definitions: each site (zeros; the boxed value), before the
		// instruction it counts from, and the stores
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
			var c = accValue(st);
			if (vars[v].ty == I64 && f.vals[c].ty == F64) {
				var x = newIns(FToBits, I64, st.block, st);
				x.a = c;
				c = x.id;
			}
			stored.set(st.id, c);
			return c;
		}
		function siteValue(s:Site, v:Int):Int {
			if (s.box > 0) return s.v.a;
			return zero(vars[v].ty);
		}
		// what one instruction defines (cur: the variables' values)
		function define(i:MIns, cur:Vector<Int>) {
			var s = siteDef.get(i.id);
			if (s != null)
				for (v in 0...n)
					cur[v] = siteValue(s, v);
			var zv = zeroVars.get(i.id);
			if (zv != null)
				for (w in zv)
					cur[w] = zero(vars[w].ty);
			if (accValue(i) < 0) return;
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
		var readers = new Vector<SsaReader>(n);
		for (v in 0...n) {
			var ty = vars[v].ty;
			readers[v] = new SsaReader(f.entry, NONE, endsOf[v], MFunc.ints(nb, NOTSET), b -> {
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
				if (i.op != GetField && i.op != Unbox && i.op != Load) continue;
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
		// the stores go; the cells and the cold sites keep null; the tests
		// know the object is not null
		for (u in g.accesses)
			if (accValue(u) >= 0 && rooted.indexOf(u) < 0) u.dead = true;
		var z64 = g.cellStores.length > 0 || g.spills.length > 0 ? zero(I64) : -1;
		for (u in g.cellStores)
			u.c = z64;
		var aliasSet = new Map<Int, Bool>();
		for (x in g.aliases)
			aliasSet.set(x, true);
		for (u in g.spills)
			for (k in 0...u.info.nspill)
				if (aliasSet.exists(u.args[k])) u.args[k] = z64;
		for (u in g.nulls)
			if (u.op == NullCheck) u.dead = true else toConst(u, u.imm == CEq ? 0 : 1);
		for (x in g.aliases)
			f.vals[x].dead = true;
		// the allocations go
		for (s in g.sites)
			s.v.dead = true;
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

	// a field read, a load or an unboxing i reads x, the value of variable r
	function read(i:MIns, x:Int, r:Var) {
		var b = i.block;
		if (i.op == Unbox) {
			var conv = i.info.t == TF64 && r.ty == I32;
			i.op = conv ? I2F : Copy;
			i.a = x;
			i.info = null;
			return;
		}
		var size = i.op == Load ? i.size : accSize(i), signed = i.signed, ty = i.ty;
		i.info = null;
		i.b = -1;
		i.c = -1;
		i.imm = 0;
		i.imm2 = 0;
		i.size = 0;
		i.signed = false;
		i.mem = 0;
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
}

private class Site {
	public var v:MIns; // the New or the Box
	public var block:MBlock; // where its values are defined (a New's continuation)
	public var box = 0; // 1 Int, 2 Float, 3 Int64 (0: an object)
	public var raw = false; // Mem.alloc's: its words read and written by hxmc.unsafe's loads and stores
	public var key:Null<String>; // the layout: a group's sites agree
	public var defAt:MIns; // the instruction its values are defined before

	public function new(v, block) {
		this.v = v;
		this.block = block;
	}

	public function what():String {
		if (box > 0) return "box" + box;
		var o = v.info;
		return o.cls != null ? o.cls.name : o.ctor != null ? o.ctor.en.name + "." + o.ctor.name : o.lambda != null ? "closure " + o.lambda.sig.key : o.shape != null ? "anon "
			+ o.shape.id : o.name;
	}
}

private class Group {
	public var root:Int;
	public var sites:Array<Site> = [];
	public var aliases:Array<Int> = [];
	public var accesses:Array<MIns> = []; // field reads and writes, unboxings
	public var bases:Array<Int> = []; // the alias each access goes through
	public var cellStores:Array<MIns> = [];
	public var nulls:Array<MIns> = [];
	public var spills:Array<MIns> = []; // cold sites' GC points keeping an alias
	public function new(root)
		this.root = root;

	public function access(u:MIns, x:Int) {
		accesses.push(u);
		bases.push(x);
	}
}

private class Var {
	public var off:Int;
	public var size:Int;
	public var ty:MTy;
	public var ref = false; // a reference (a slot of the frame)

	public function new(off, size, ty) {
		this.off = off;
		this.size = size;
		this.ty = ty;
	}
}
