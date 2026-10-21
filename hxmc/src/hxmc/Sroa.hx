package hxmc;

import hxmc.Mir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Scalar replacement of frame slots (after inlining, before Opt): a slot
// whose address is only the base of loads and stores at constant offsets
// (a struct value of the function that no call takes, FnLower.newSlot) has
// its accesses replaced by SSA values, one variable per accessed range: a
// store defines it, a load reads it (phis where paths join, Braun et al.'s
// construction on the finished graph; zero before any store). A slot with
// ranges that partly overlap, an access of another shape or an escaping
// address stays in memory, as do the slots of a function that calls setjmp
// (a second return finds memory, not registers, as it was).
class Sroa {
	var f:MFunc;

	public function new(f:MFunc)
		this.f = f;

	public function run() {
		if (f.slots.length == 0) return;
		for (b in f.blocks)
			for (i in b.ins)
				if (i.op == Call && i.returnsTwice) return;
		// the uses of each value (StackAddr and its copies), per slot
		var addrs = new Vector<Array<MIns>>(f.slots.length);
		for (s in 0...addrs.length)
			addrs[s] = [];
		var any = false;
		for (b in f.blocks)
			for (i in b.ins)
				if (i.op == StackAddr && !i.dead) {
					addrs[i.imm].push(i);
					any = true;
				}
		if (!any) return;
		var uses = new Vector<Null<Array<MIns>>>(f.vals.length);
		inline function use(v:Int, i:MIns) {
			if (uses[v] == null) uses[v] = [];
			uses[v].push(i);
		}
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.a >= 0) use(i.a, i);
				if (i.b >= 0) use(i.b, i);
				if (i.c >= 0) use(i.c, i);
				for (x in i.args)
					use(x, i);
			}
		for (s in 0...f.slots.length)
			if (addrs[s].length > 0) promote(s, addrs[s], uses);
		if (phis.length > 0) trivialPhis();
	}

	var phis:Array<MIns> = [];

	// the phis made whose operands are one value (or the phi itself) become copies of it
	function trivialPhis() {
		var changed = true;
		while (changed) {
			changed = false;
			for (p in phis) {
				if (p.op != Phi) continue;
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

	var copies:Array<MIns> = []; // (of the addresses of the slot being promoted)

	// the accesses of slot s, or null when it cannot be promoted
	function accesses(roots:Array<MIns>, uses:Vector<Null<Array<MIns>>>):Null<Array<MIns>> {
		var r = [];
		copies = [];
		var work = roots.copy();
		var seen = new Map<Int, Bool>();
		while (work.length > 0) {
			var a = work.pop();
			if (seen.exists(a.id)) continue;
			seen.set(a.id, true);
			var us = uses[a.id];
			if (us == null) continue;
			for (u in us)
				switch u.op {
					case Copy:
						work.push(u);
						copies.push(u);
					case Load if (u.a == a.id && u.b < 0):
						if (!shapeOk(u.ty, u.size)) return null;
						r.push(u);
					case Store if (u.a == a.id && u.b < 0 && u.c != a.id):
						if (!shapeOk(f.vals[u.c].ty, u.size)) return null;
						r.push(u);
					case _: return null;
				}
		}
		return r;
	}

	static inline function shapeOk(t:MTy, size:Int):Bool
		return size == 8 && (t == I64 || t == F64) || size <= 4 && t == I32;

	function promote(s:Int, roots:Array<MIns>, uses:Vector<Null<Array<MIns>>>) {
		var acc = accesses(roots, uses);
		if (acc == null) return;
		// the ranges: identical or disjoint
		var vars:Array<{off:Int, size:Int, ty:MTy}> = [];
		var varOf = new Map<Int, Int>(); // access -> variable
		for (i in acc) {
			var v = -1;
			for (k in 0...vars.length) {
				var x = vars[k];
				if (x.off == i.imm && x.size == i.size) v = k else if (i.imm < x.off + x.size && x.off < i.imm + i.size) return;
			}
			var t = i.op == Load ? i.ty : f.vals[i.c].ty;
			if (v < 0) {
				v = vars.length;
				vars.push({off: i.imm, size: i.size, ty: t});
			} else if (vars[v].ty != t) vars[v].ty = I64; // (doubles and words: words)
			varOf.set(i.id, v);
		}
		if (vars.length == 0) return;
		// the value of each variable at the end of each block (its last store)
		var nb = 0;
		for (b in f.blocks)
			if (b.id >= nb) nb = b.id + 1;
		var lastStore = new Vector<Null<Map<Int, MIns>>>(nb);
		var touched = new Vector<Bool>(nb);
		for (b in f.blocks)
			for (i in b.ins)
				if (varOf.exists(i.id)) {
					touched[b.id] = true;
					if (i.op == Store) {
						if (lastStore[b.id] == null) lastStore[b.id] = new Map();
						lastStore[b.id].set(varOf.get(i.id), i);
					}
				}
		// conversions are made where the value is (new instructions before
		// the access, or at the end of a block before its terminator)
		var stored = new Map<Int, Int>(); // store -> the variable's value it gives
		var entryVal = new Map<String, Int>();
		var zeros = new Vector<Int>(vars.length, -1);
		var pending:Array<{b:MBlock, at:MIns, i:MIns}> = []; // instructions to insert
		function newIns(op:Op, ty:MTy, b:MBlock, before:MIns):MIns {
			var x = new MIns(op, ty);
			x.id = f.vals.length;
			f.vals.push(x);
			x.block = b;
			pending.push({b: b, at: before, i: x});
			return x;
		}
		function zero(v:Int):Int {
			if (zeros[v] >= 0) return zeros[v];
			var e = f.entry;
			var at = e.ins[0];
			for (i in e.ins)
				if (i.op != Phi && i.op != Param) {
					at = i;
					break;
				}
			var t = vars[v].ty;
			var z = newIns(t == F64 ? ConstF : Const, t, e, at);
			zeros[v] = z.id;
			return z.id;
		}
		// the value a store gives its variable (converted to the variable's type)
		function storedValue(st:MIns):Int {
			var r = stored.get(st.id);
			if (r != null) return r;
			var v = varOf.get(st.id);
			var c = st.c;
			if (vars[v].ty == I64 && f.vals[c].ty == F64) {
				var x = newIns(FToBits, I64, st.block, st);
				x.a = c;
				c = x.id;
			}
			stored.set(st.id, c);
			return c;
		}
		var readEnd:(Int, MBlock) -> Int = null;
		function readEntry(v:Int, b:MBlock):Int {
			var key = v + ":" + b.id;
			var r = entryVal.get(key);
			if (r != null) return r;
			if (b == f.entry || b.preds.length == 0) {
				r = zero(v);
			} else if (b.preds.length == 1) {
				r = readEnd(v, b.preds[0]);
			} else {
				var phi = new MIns(Phi, vars[v].ty);
				phi.id = f.vals.length;
				f.vals.push(phi);
				phi.block = b;
				phis.push(phi);
				var k = 0;
				while (k < b.ins.length && b.ins[k].op == Phi)
					k++;
				b.ins.insert(k, phi);
				entryVal.set(key, phi.id);
				var args = new Vector<Int>(b.preds.length);
				for (q in 0...args.length)
					args[q] = readEnd(v, b.preds[q]);
				phi.args = args;
				return phi.id;
			}
			entryVal.set(key, r);
			return r;
		}
		readEnd = (v, b) -> {
			var ls = lastStore[b.id];
			var st = ls != null ? ls.get(v) : null;
			st != null ? storedValue(st) : readEntry(v, b);
		};
		// the loads become their variable's value; the stores go
		for (b in f.blocks) {
			if (!touched[b.id]) continue;
			var cur = new Map<Int, Int>();
			for (i in b.ins.copy()) {
				var v = varOf.get(i.id);
				if (v == null) continue;
				if (i.op == Store) {
					cur.set(v, storedValue(i));
					i.dead = true;
					continue;
				}
				var x = cur.exists(v) ? cur.get(v) : readEntry(v, b);
				var t = vars[v].ty;
				// the load itself turns into the conversion (or a copy)
				i.b = -1;
				i.c = -1;
				i.imm = 0;
				i.imm2 = 0;
				if (i.ty == F64 && t == I64) {
					i.op = BitsToF;
					i.a = x;
				} else if (i.size < 4) {
					var bits = 32 - 8 * i.size;
					var k = newIns(Const, I32, b, i);
					if (i.signed) {
						k.imm = bits;
						var sh = newIns(Shl, I32, b, i);
						sh.a = x;
						sh.b = k.id;
						i.op = Sar;
						i.a = sh.id;
						i.b = k.id;
					} else {
						k.imm = i.size == 1 ? 0xFF : 0xFFFF;
						i.op = And;
						i.a = x;
						i.b = k.id;
					}
				} else {
					i.op = Copy;
					i.a = x;
				}
				i.size = 0;
				i.signed = false;
				i.mem = 0;
			}
		}
		for (p in pending) {
			var ins = p.b.ins;
			var k = ins.indexOf(p.at);
			if (k < 0) k = ins.length;
			ins.insert(k, p.i);
		}
		for (b in f.blocks) {
			var ins = b.ins, k = 0;
			for (i in ins)
				if (!i.dead) ins[k++] = i;
			if (k < ins.length) ins.resize(k);
		}
		// (the slot is no longer used: no room in the frame)
		for (r in roots)
			r.dead = true;
		for (c in copies)
			c.dead = true;
		for (b in f.blocks) {
			var ins = b.ins, k = 0;
			for (i in ins)
				if (!i.dead) ins[k++] = i;
			if (k < ins.length) ins.resize(k);
		}
		f.slots[s] = {size: 0, align: 1};
	}
}
