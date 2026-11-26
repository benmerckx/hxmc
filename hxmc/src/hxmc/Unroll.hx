package hxmc;

import hxmc.Mir;

// Full unrolling (object-level Mir, before LoopVersion and Opt): an
// innermost loop whose counter runs a constant number of rounds (a
// constant start, a constant limit its header tests, constant steps on the
// way back), of at most MAX_ROUNDS rounds and MAX_SIZE instructions in
// all, without cold sites, runs as that many copies of its body. Each
// round is peeled: a copy of the loop entered from before it, whose way
// back enters the loop (LoopVersion.copyLoop). After the last, the loop's
// header tests constants, and Opt removes it; in the copies the counter is
// a constant, so what a round indexes with it is at a constant offset.
class Unroll {
	static inline var MAX_ROUNDS = 16;
	static inline var MAX_SIZE = 320;
	// at most this many loops unrolled per function
	static inline var MAX_LOOPS = 4;

	public static function run(f:MFunc):Int {
		if (f.allRegs) return 0;
		var n = 0;
		var tried = new Map<Int, Bool>();
		while (n < MAX_LOOPS) {
			var cfg = f.cfg();
			cfg.loops();
			if (cfg.irreducible) break;
			var order = cfg.rpo, bodies = cfg.loopBodies();
			var any = false;
			var k = order.length;
			while (k-- > 1) {
				var h = order[k];
				var ks = bodies[k];
				if (ks == null || tried.exists(h.id)) continue;
				tried.set(h.id, true);
				var members = [for (x in ks) order[x]];
				// (innermost: no other header among its blocks)
				if (Lambda.exists(ks, x -> x != k && cfg.loopHead[x] == x)) continue;
				var rounds = roundsOf(f, h, members);
				if (rounds <= 0) continue;
				var lv = new LoopVersion(f);
				var inL = [for (b in members) b.id => true];
				var pre = inL.exists(h.preds[0].id) ? 1 : 0, latch = 1 - pre;
				for (_ in 0...rounds) {
					peel(lv, f, h, members, b -> b != null && inL.exists(b.id), pre, latch);
					f.edited();
					cfg = f.cfg();
					cfg.loops();
				}
				n++;
				any = true;
				break;
			}
			if (!any) break;
		}
		return n;
	}

	// One round of the loop before it: a copy entered from before the loop,
	// its way back entering the loop's header (whose phis take the copy's
	// values there)
	static function peel(lv:LoopVersion, f:MFunc, h:MBlock, members:Array<MBlock>, inLoop:Null<MBlock>->Bool, pre:Int, latch:Int) {
		var cfg = f.cfg();
		cfg.loops();
		var preB = h.preds[pre];
		lv.copyLoop(h, members, inLoop, cfg, (_, _) -> {}, h2 -> {
			LoopVersion.retargetTerm(preB, h, h2);
			preB.succs[preB.succs.indexOf(h)] = h2;
			var l2 = h2.preds[latch];
			LoopVersion.retargetTerm(l2, h2, h);
			l2.succs[l2.succs.indexOf(h2)] = h;
			var hp = [for (i in h.ins) if (i.op == Phi) i], hp2 = [for (i in h2.ins) if (i.op == Phi) i];
			for (q in 0...hp.length) {
				var args = hp[q].args.copy();
				args[pre] = hp2[q].args[latch];
				hp[q].args = args;
				hp2[q].removeArg(latch);
			}
			h.preds[pre] = l2;
			h2.preds.splice(latch, 1);
		});
	}

	// the rounds of a counted loop of constants (0: not one)
	static function roundsOf(f:MFunc, h:MBlock, members:Array<MBlock>):Int {
		var inL = [for (b in members) b.id => true];
		inline function inLoop(b:Null<MBlock>):Bool
			return b != null && inL.exists(b.id);
		if (h.preds.length != 2 || h.handler) return 0;
		var latch = inLoop(h.preds[0]) ? 0 : 1, pre = 1 - latch;
		if (!inLoop(h.preds[latch]) || inLoop(h.preds[pre])) return 0;
		var size = 0;
		for (b in members)
			for (i in b.ins) {
				if (i.dead) continue;
				size++;
				if (b.handler || i.info != null && i.info.cold || i.op == Call && i.returnsTwice || i.op == Switch || i.op == AnonTest) return 0;
			}
		var t = h.term();
		if (t == null || t.op != Br) return 0;
		var stay = inLoop(t.targets[0]) ? 0 : inLoop(t.targets[1]) ? 1 : -1;
		if (stay < 0 || inLoop(t.targets[1 - stay])) return 0;
		var c = f.vals[t.a];
		if (c.op != Cmp || c.block != h || c.a < 0 || c.b < 0) return 0;
		inline function konst(v:Int):Null<Int> {
			var x = f.vals[v];
			return x.op == Const && x.sym == null && x.ty == I32 ? x.imm : null;
		}
		// the counter: a phi of the header, either side of the comparison
		var ivLeft = true;
		var iv = f.vals[c.a], lim = konst(c.b);
		if (iv.op != Phi || iv.block != h) {
			iv = f.vals[c.b];
			lim = konst(c.a);
			ivLeft = false;
		}
		if (iv.op != Phi || iv.block != h || iv.ty != I32 || lim == null) return 0;
		var start = konst(iv.args[pre]);
		if (start == null) return 0;
		// the step: constants added to the counter on the way back
		var step = 0, x = f.vals[iv.args[latch]], depth = 0;
		while (x.id != iv.id) {
			if (x.op != Add || depth++ > 8) return 0;
			var k = konst(x.b);
			if (k == null) return 0;
			step += k;
			x = f.vals[x.a];
		}
		if (step == 0) return 0;
		inline function holds(v:Int):Bool {
			var a = ivLeft ? v : lim, b = ivLeft ? lim : v;
			var r = switch (c.imm : Cond) {
				case CLt: a < b;
				case CLe: a <= b;
				case CGt: a > b;
				case CGe: a >= b;
				case CNe: a != b;
				case CEq: a == b;
				case _: false;
			};
			return r == (stay == 0);
		}
		var rounds = 0, v = start;
		while (holds(v)) {
			if (++rounds > MAX_ROUNDS || rounds * size > MAX_SIZE) return 0;
			// (the counter is an Int: no wrapping past the limit)
			if (v + step > 0x3FFFFFFF || v + step < -0x3FFFFFFF) return 0;
			v += step;
		}
		return rounds;
	}
}
