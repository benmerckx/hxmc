package hxmc;

import hxmc.Mir;

// Float counters as Ints (object-level Mir, before Unroll, LoopVersion and
// Opt): a loop header's Float phi that starts at an Int (an integral
// constant in the Int range, an Int converted, or the counter of a loop it
// is in plus one), goes up or down by one on the way back, and that the
// header's test keeps strictly below (above) an Int (an Int converted, as an
// array's length read each round, or an integral constant) is an Int: it
// steps only after the test found it below an Int, so every value it takes
// is an integer in the Int range, exact as a Float, and the Int's steps and
// comparison are the Float's. Its Float uses read the Int
// converted (Opt then folds Std.int of it, and its tests against the Int
// range, MirBuild.f2i). JavaScript numbers counting over an array's length
// (helder's lowering) and Haxe Float counters are this shape.
class FloatCounters {
	public static function run(f:MFunc):Int {
		var cfg = f.cfg();
		cfg.loops();
		if (cfg.irreducible) return 0;
		var order = cfg.rpo, bodies = cfg.loopBodies();
		var vals = f.vals;
		// the counters made, below their bound in their loop (not its header)
		var below = new Map<Int, {h:MBlock, inL:Map<Int, Bool>}>();
		var n = 0;
		function add(b:MBlock, at:Int, op:Op, ty:MTy):MIns {
			var x = new MIns(op, ty);
			x.id = vals.length;
			vals.push(x);
			x.block = b;
			b.ins.insert(at, x);
			return x;
		}
		// at the end of b (before its terminator)
		function append(b:MBlock, op:Op, ty:MTy):MIns
			return add(b, b.ins.length - 1, op, ty);
		inline function intConst(v:MIns):Null<Int> {
			if (v.op != ConstF || v.f != Math.ffloor(v.f) || v.f < -2147483648.0 || v.f > 2147483647.0) return null;
			return Std.int(v.f);
		}
		for (k in 1...order.length) {
			var ks = bodies[k];
			if (ks == null) continue;
			var h = order[k];
			if (h.handler || h.preds.length != 2) continue;
			var inL = new Map<Int, Bool>();
			for (x in ks)
				inL.set(order[x].id, true);
			inline function inLoop(b:Null<MBlock>):Bool
				return b != null && inL.exists(b.id);
			var latch = inLoop(h.preds[0]) ? 0 : 1, pre = 1 - latch;
			if (!inLoop(h.preds[latch]) || inLoop(h.preds[pre])) continue;
			var preB = h.preds[pre];
			if (preB.term() == null) continue;
			var t = h.term();
			if (t == null || t.op != Br) continue;
			var stay = inLoop(t.targets[0]) ? 0 : inLoop(t.targets[1]) ? 1 : -1;
			if (stay < 0 || inLoop(t.targets[1 - stay])) continue;
			// (a negated test, `!(i < n)`: its comparison with 0, the other way)
			var c = vals[t.a], negated = false;
			while (c.op == Cmp && (c.imm == (CEq : Int) || c.imm == (CNe : Int)) && c.b >= 0 && vals[c.b].op == Const && vals[c.b].sym == null
				&& vals[c.b].imm == 0 && c.a >= 0 && vals[c.a].op == Cmp && vals[c.a].block == h) {
				if (c.imm == (CEq : Int)) {
					stay = 1 - stay;
					negated = !negated;
				}
				c = vals[c.a];
			}
			if (c.op != Cmp || c.block != h || c.imm < (FEq : Int)) continue;
			for (phi in h.ins.copy()) {
				if (phi.op != Phi) break;
				if (phi.dead || phi.ty != F64 || phi.args.length != 2 || c.dead) continue;
				// the step: one more or one less on the way back
				var l = vals[phi.args[latch]];
				var one = (v:Int) -> vals[v].op == ConstF && vals[v].f == 1.0;
				var step = l.op == FAdd && (l.a == phi.id && one(l.b) || l.b == phi.id && one(l.a)) ? 1 : l.op == FSub && l.a == phi.id && one(l.b) ? -1 : 0;
				if (step == 0 || !inLoop(l.block)) continue;
				// the test: phi against a bound (cond: phi cond bound)
				var cond:Cond = c.imm, other = -1;
				if (c.a == phi.id) other = c.b else if (c.b == phi.id) {
					other = c.a;
					cond = switch cond {
						case FLt: FGt;
						case FGt: FLt;
						case FLe: FGe;
						case FGe: FLe;
						case x: x;
					};
				}
				if (other < 0 || other == phi.id) continue;
				// (what keeps it in the loop: no NaN on either side, so the
				// negation of an order is the other order)
				var keep:Cond = stay == 0 ? cond : switch cond {
					case FLt: FGe;
					case FGe: FLt;
					case FGt: FLe;
					case FLe: FGt;
					case FEq: FNe;
					case _: FEq;
				};
				if (!(step == 1 && keep == FLt || step == -1 && keep == FGt)) continue;
				var bv = vals[other];
				var bound = -1;
				if (bv.op == I2F && bv.a >= 0 && vals[bv.a].ty == I32) bound = bv.a else {
					var kb = intConst(bv);
					if (kb == null) continue;
					var x = append(preB, Const, I32);
					x.imm = kb;
					bound = x.id;
				}
				// the start: an Int (a constant, converted, or a counter of a
				// loop this one is in, plus one)
				var sv = vals[phi.args[pre]];
				var start = -1;
				var ks0 = intConst(sv);
				if (ks0 != null) {
					var x = append(preB, Const, I32);
					x.imm = ks0;
					start = x.id;
				} else if (sv.op == I2F && sv.a >= 0 && vals[sv.a].ty == I32) start = sv.a else if (sv.op == FAdd) {
					var u = vals[sv.a].op == I2F ? vals[sv.a] : vals[sv.b].op == I2F ? vals[sv.b] : null;
					var k1 = u == null ? null : vals[u == vals[sv.a] ? sv.b : sv.a];
					var outer = u == null ? null : below.get(u.a);
					if (outer != null && k1 != null && k1.op == ConstF && k1.f == 1.0 && preB != outer.h && outer.inL.exists(preB.id)) {
						// (below its bound inside its loop: one more is an Int)
						var inc = append(preB, Const, I32);
						inc.imm = 1;
						var s = append(preB, Add, I32);
						s.a = u.a;
						s.b = inc.id;
						start = s.id;
					}
				}
				if (start < 0) continue;
				// the Int counter, its step, its Float value for the other uses
				var ip = add(h, 0, Phi, I32);
				ip.vty = hxmc.ir.Ir.Ty.TI32;
				var d = append(preB, Const, I32);
				d.imm = step;
				var li = add(l.block, l.block.ins.indexOf(l), Add, I32);
				li.a = ip.id;
				li.b = d.id;
				var args = new haxe.ds.Vector<Int>(2);
				args[pre] = start;
				args[latch] = li.id;
				ip.args = args;
				var at = 0;
				while (at < h.ins.length && h.ins[at].op == Phi)
					at++;
				var fv = add(h, at, I2F, F64);
				fv.a = ip.id;
				fv.vty = phi.vty;
				for (b in f.blocks)
					for (i in b.ins) {
						if (i == phi || i.dead) continue;
						if (i.a == phi.id) i.a = fv.id;
						if (i.b == phi.id) i.b = fv.id;
						if (i.c == phi.id) i.c = fv.id;
						for (q in 0...i.args.length)
							if (i.args[q] == phi.id) {
								var na = i.args.copy();
								na[q] = fv.id;
								i.args = na;
							}
					}
				// (the test of the Float, of the Int now: the same order, no NaN)
				c.a = c.a == fv.id ? ip.id : bound;
				c.b = c.b == fv.id ? ip.id : bound;
				c.imm = switch (c.imm : Cond) {
					case FLt: CLt;
					case FLe: CLe;
					case FGt: CGt;
					case FGe: CGe;
					case FEq: CEq;
					case _: CNe;
				};
				// (the branch on the Int comparison itself, its targets the other way
				// for a negated test: LoopVersion's shape)
				if (t.a != c.id) {
					t.a = c.id;
					if (negated) {
						t.targets = haxe.ds.Vector.fromArrayCopy([t.targets[1], t.targets[0]]);
						h.succs = [t.targets[0], t.targets[1]];
					}
					negated = false;
				}
				phi.dead = true;
				h.ins.remove(phi);
				if (step == 1) below.set(ip.id, {h: h, inL: inL});
				n++;
			}
		}
		if (n > 0) f.edited();
		return n;
	}
}
