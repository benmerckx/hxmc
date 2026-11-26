package hxmc;

import haxe.ds.Vector;
import hxmc.ir.Ir;
import hxmc.Mir;

using core.ds.VectorTools;

// Objects in the frame (object-level Mir, after the optimizer): a class
// instance without reference fields whose only escapes are calls of
// functions that do not retain it (FuncInfo.retains, MIns.retains) lives
// in a slot of its function's frame instead of the heap (OInfo.frame,
// MemLower.frameObject): no allocation, no GC point. Nothing can reach it
// once its function returns: its aliases (copies, phis of them alone, what
// is read back from a shadow-stack slot only they were stored into) are
// read and written through, tested, compared, kept by a cold site across
// its slow path, and passed to parameters that are not retained. The
// collector leaves pointers outside its spaces alone, and the object holds
// none it would have to follow. A site in a loop reuses its slot: an object
// of the round before is no alias once a new one is made (a phi with it
// would be one of other values too).
class FrameAlloc {
	public static function run(f:MFunc):Int {
		var users = new Map<Int, Array<MIns>>();
		var sites:Array<MIns> = [];
		var vals = f.vals;
		function user(v:Int, i:MIns) {
			if (v < 0) return;
			var l = users.get(v);
			if (l == null) users.set(v, l = []);
			if (l.length == 0 || l[l.length - 1] != i) l.push(i);
		}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.op == Call && i.returnsTwice) return 0;
				user(i.a, i);
				user(i.b, i);
				user(i.c, i);
				for (x in i.args)
					user(x, i);
				if (i.op == New && candidate(i.info)) sites.push(i);
			}
		if (sites.length == 0) return 0;
		var cfg = f.cfg();
		cfg.loops();
		var n = 0;
		for (s in sites) {
			var k = cfg.index(s.block);
			if (k >= 0 && fits(s, users, f.blocks, vals, cfg.loopHead[k] >= 0)) {
				s.info.frame = true;
				n++;
			}
		}
		return n;
	}

	// a class instance of scalar fields only, of no other object system (a
	// peer of an Objective-C, COM or Java object: the runtime pairs it)
	static function candidate(o:OInfo):Bool {
		if (o.name != OInfo.NEW_OBJECT || o.cls == null || o.kind != Abi.K_OBJ) return false;
		for (x in o.cls.fields)
			if (Ir.isRef(x.ty) || x.ty.match(TId)) return false;
		var c = o.cls;
		while (c != null) {
			if (c.objc != null || c.com != null || c.jni != null || c.jniProxy != null || c.idFields.length > 0 || c.weakFields.length > 0
				|| c.unownedFields.length > 0)
				return false;
			c = c.sup;
		}
		return true;
	}

	static function fits(s:MIns, users:Map<Int, Array<MIns>>, blocks:Array<MBlock>, vals:Array<MIns>, inLoop:Bool):Bool {
		var alias = new Map<Int, Bool>();
		var work = [s.id];
		alias.set(s.id, true);
		var phis:Array<MIns> = [];
		// shadow-stack slots it was stored into (their loads are aliases, once
		// every store there is of an alias or null)
		var slots = new Map<Int, Bool>();
		function add(v:Int) {
			if (!alias.exists(v)) {
				alias.set(v, true);
				work.push(v);
			}
		}
		inline function isAlias(v:Int):Bool
			return v >= 0 && alias.exists(v);
		while (work.length > 0) {
			var v = work.pop();
			var us = users.get(v);
			if (us == null) continue;
			for (u in us) {
				switch u.op {
					case Copy:
						add(u.id);
					case Phi:
						phis.push(u);
						add(u.id);
					case GetField | NullCheck | TypeTest if (u.a == v):
					case SetField | InitField if (u.a == v && !isAlias(u.b)):
					case Cmp:
					case Call if (u.a != v && u.sym != null && !u.returnsTwice && u.retains != -1):
						for (k in 0...u.args.length)
							if (u.args[k] == v && (k > 30 || u.retains & (1 << k) != 0)) return false;
					case New | NewDyn | ArraySet | ArrayPush | NewNArray | NArrayDyn if (u.info.cold && u.a != v && u.b != v && u.c != v):
						var k = u.args.indexOf(v);
						if (k < 0 || k >= u.info.nspill) return false;
					case Store if (u.c == v && u.a != v && u.b < 0 && u.mem == Opt.MFrame):
						var key = slotKey(u, vals);
						// (in a loop, what a slot holds may be the object of a round before)
						if (key < 0 || inLoop) return false;
						slots.set(key, true);
					case _:
						return false;
				}
			}
			// (the loads of its slots: aliases)
			if (work.length == 0)
				for (l in loadsOf(slots, blocks, vals))
					add(l);
		}
		for (p in phis)
			for (a in p.args)
				if (a != p.id && !isAlias(a)) return false;
		// (every store into its slots: of an alias, or null)
		for (st in storesOf(slots, blocks, vals))
			if (!isAlias(st.c) && !isNull(vals[st.c])) return false;
		return true;
	}

	static inline function isNull(x:MIns):Bool
		return x.op == Const && x.sym == null && x.imm == 0 && x.imm2 == 0;

	static function loadsOf(slots:Map<Int, Bool>, blocks:Array<MBlock>, vals:Array<MIns>):Array<Int> {
		var out = [];
		if (!slots.iterator().hasNext()) return out;
		for (b in blocks)
			for (i in b.ins)
			if (!i.dead && i.op == Load && i.mem == Opt.MFrame && i.ty == I64 && slots.exists(slotKey(i, vals))) out.push(i.id);
		return out;
	}

	static function storesOf(slots:Map<Int, Bool>, blocks:Array<MBlock>, vals:Array<MIns>):Array<MIns> {
		var out = [];
		if (!slots.iterator().hasNext()) return out;
		for (b in blocks)
			for (i in b.ins)
			if (!i.dead && i.op == Store && i.mem == Opt.MFrame && slots.exists(slotKey(i, vals))) out.push(i);
		return out;
	}

	// a load's or store's slot when its address is rt_sp plus a constant (-1:
	// other memory; Escape.slotKey)
	static function slotKey(i:MIns, vals:Array<MIns>):Int {
		if (i.b >= 0 || i.size != 8) return -1;
		var v = i.a, off = i.imm, n = 0;
		while (n++ < 16) {
			var x = vals[v];
			if (x.op == Copy) v = x.a else if (x.op == Add) {
				var c = vals[x.b];
				if (c.op != Const || c.sym != null) return -1;
				off += c.imm;
				v = x.a;
			} else break;
		}
		var r = vals[v];
		return r.op == TlsLoad && r.sym == "rt_sp" ? r.id * 1024 + ((off >> 3) & 1023) : -1;
	}
}
