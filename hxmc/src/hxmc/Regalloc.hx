package hxmc;

import hxmc.Lir;
import hxmc.Lir.Arrays;

// What the register allocator needs to know about a target.
interface RegTarget {
	// the registers an instruction reads and writes, including fixed
	// physical ones and the registers a call clobbers (as definitions)
	function defsUses(i:LIns, defs:RegList, uses:RegList):Void;
	// a register to register copy: d <- s1
	function isMove(i:LIns):Bool;
	// allocatable registers in order of preference (caller-saved first)
	var gprs(default, null):Array<Int>;
	var fprs(default, null):Array<Int>;
	function spillLoad(r:Int, slot:Int, float:Bool):LIns;
	function spillStore(slot:Int, r:Int, float:Bool):LIns;
	// calls: the registers that hold their results (the other registers a
	// call defines are clobbered)
	function isCall(i:LIns):Bool;
	// the jumps that end a block
	function isBranch(i:LIns):Bool;
	var callResults(default, null):Array<Int>;
}

// a list of registers that keeps its storage (defsUses fills one per instruction)
class RegList {
	public var a:Array<Int> = [for (_ in 0...64) 0];
	public var n = 0;

	public function new() {}

	public inline function push(r:Int) {
		if (n == a.length) a.push(r) else a[n] = r;
		n++;
	}
}

// The allocator's working storage, kept from one function to the next (one
// per thread): the arrays keep their capacity, so a round allocates little.
class Scratch {
	public var defs = new RegList();
	public var uses = new RegList();
	public var start:Array<Int> = [];
	public var end:Array<Int> = [];
	public var fixedFrom:Array<Array<Int>> = [for (_ in 0...LFunc.NPHYS) []];
	public var fixedTo:Array<Array<Int>> = [for (_ in 0...LFunc.NPHYS) []];
	public var openFixed:haxe.ds.Vector<Int> = Arrays.filled(LFunc.NPHYS, -1);
	public var exposedHead:Array<Int> = [];
	public var exposedBlock:Array<Int> = [];
	public var exposedNext:Array<Int> = [];
	public var defStamp:Array<Int> = [];
	public var defHead:Array<Int> = [];
	public var defBlock:Array<Int> = [];
	public var defNext:Array<Int> = [];
	public var defines:Array<Int> = [];
	public var liveInSeen:Array<Int> = [];
	public var liveOutSeen:Array<Int> = [];
	public var work:Array<Int> = [];
	public var count:Array<Int> = [];
	public var order:Array<Int> = [];
	public var assigned:Array<Int> = [];
	public var occHead:Array<Int> = [];
	public var occNext:Array<Int> = [];
	public var occBlock:Array<Int> = [];
	public var occFirst:Array<Int> = [];
	public var occLast:Array<Int> = [];
	public var occAt:Array<Int> = [];
	public var listed:Array<Int> = [];
	public var bl:Array<Int> = [];
	public var segAt:Array<Int> = [];
	public var segN:Array<Int> = [];
	public var segFrom:Array<Int> = [];
	public var segTo:Array<Int> = [];
	public var len:Array<Int> = [];
	public var fixLo:Array<Int> = [];
	public var fixHi:Array<Int> = [];
	public var ptB:Array<Int> = [];
	public var ptR:Array<Int> = [];
	public var ptLo:Array<Int> = [];
	public var ptHi:Array<Int> = [];
	public var ptAt:Array<Int> = [];
	public var ptVal:Array<Int> = [];
	public var ptFill:Array<Int> = [];
	public var ptBlocks:Array<Int> = [];
	public var pB:Array<Int> = [];
	public var pR:Array<Int> = [];
	public var pA:Array<Int> = [];
	public var pZ:Array<Int> = [];
	public var bucket:Array<Int> = [];
	public var sorted:Array<Int> = [];
	public var oFrom:Array<Array<Int>> = [for (_ in 0...LFunc.NPHYS) []];
	public var oTo:Array<Array<Int>> = [for (_ in 0...LFunc.NPHYS) []];
	public var oOwn:Array<Array<Int>> = [for (_ in 0...LFunc.NPHYS) []];
	public var oPend:Array<Array<Int>> = [for (_ in 0...LFunc.NPHYS) []];
	public var pendSeg:Array<Int> = [];
	public var pendOwn:Array<Int> = [];
	public var pendIdx:Array<Int> = [];
	public var mFrom:Array<Int> = [];
	public var mTo:Array<Int> = [];
	public var mOwn:Array<Int> = [];
	public var seen:Array<Int> = [];
	public var conflicts:Array<Int> = [];
	public var weight:Array<Float> = [];
	// per physical register: whether a call leaves its result there; 1 for
	// the allocatable float registers, 2 for the integer ones
	public var isResult = new haxe.ds.Vector<Bool>(LFunc.NPHYS);
	public var isFpr:haxe.ds.Vector<Int> = Arrays.filled(LFunc.NPHYS, 0);

	public function new(t:RegTarget) {
		for (r in t.callResults)
			isResult[r] = true;
		for (c in t.fprs)
			isFpr[c] = 1;
		for (c in t.gprs)
			isFpr[c] = 2;
	}

	// whether its arrays grew past what an ordinary function needs (a million
	// positions: 500,000 instructions)
	public function oversized():Bool
		return count.length > 1 << 20;

	// a resized to n copies of v
	public static function fill(a:Array<Int>, n:Int, v:Int):Array<Int> {
		a.resize(n);
		for (i in 0...n)
			a[i] = v;
		return a;
	}
}

// Linear-scan register allocation (Poletto and Sarkar) on the block layout
// order, one register per virtual register for its whole life, with
// lifetime holes (Wimmer and Mössenböck's interval ranges, without
// splitting): values whose ranges do not overlap share a register. Physical registers
// named by instructions (call arguments and results, fixed operands, call
// clobbers) are fixed ranges no interval may overlap, so a value live across
// a call ends up in a callee-saved register or in memory. A spilled register
// lives in a frame slot: every use loads it into a fresh short-lived
// register and every definition stores it, and the allocation runs again.
class Regalloc {
	static inline var NPHYS = LFunc.NPHYS;
	var f:LFunc;
	var t:RegTarget;
	public var assigned:Array<Int>; // register -> physical register
	public var usedRegs = [for (_ in 0...LFunc.NPHYS) false]; // physical registers used
	var noSpillFrom = 0x7fffffff; // registers made by spill code are numbered from here

	public function new(f:LFunc, t:RegTarget, ?s:Scratch) {
		this.f = f;
		this.t = t;
		this.s = s != null ? s : new Scratch(t);
	}

	// From the third round on, an interval that finds no register is spilled
	// itself instead of evicting cheaper ones: each eviction moved the
	// conflict on to the next of a chain of intervals, a round each (a
	// function of 2 million values took 40 rounds of 1.5 s, now 4). Few
	// functions get there (the tool's build: 5 rounds fewer of 15,169).
	static inline var LATE = 2;
	var lateRound = false;
	public var rounds = 0; // allocation rounds run (statistics)
	public var insns = 0; // instructions they went through

	public function run() {
		// loop depths from the layout (reverse postorder, slow paths last): a
		// branch back to an earlier block closes a loop over the blocks between
		var nb = f.blocks.length;
		for (bi in 0...nb)
			f.blocks[bi].id = bi;
		for (b in f.blocks)
			b.loopDepth = 0;
		for (b in f.blocks)
			for (pr in b.preds)
				if (pr.id >= b.id && !pr.cold)
					for (k in b.id...pr.id + 1)
						f.blocks[k].loopDepth++;
		for (round in 0...64) {
			rounds++;
			for (b in f.blocks)
				insns += b.ins.length;
			lateRound = round >= LATE;
			var spilled = allocate();
			if (spilled.length == 0) {
				coldSaves();
				rewrite();
				return;
			}
			insertSpills(spilled);
		}
		throw "hxmc: register allocation does not converge in " + f.name;
	}

	// ---- one round

	var start:Array<Int>; // per virtual register: its first position (0x7fffffff: none)
	var end:Array<Int>; // its last position (-1: none)
	// its live ranges, with lifetime holes between them (e.g. where it is
	// not live in the slow paths laid out after the code): from segAt[r],
	// segN[r] of them, in position order
	var segAt:Array<Int>;
	var segN:Array<Int>;
	var segFrom:Array<Int>;
	var segTo:Array<Int>;
	var fixedFrom:Array<Array<Int>>; // per physical register: sorted ranges
	var fixedTo:Array<Array<Int>>;
	var s:Scratch;

	function allocate():Array<Int> {
		var n = f.nregs;
		var s = this.s;
		coldCalls.resize(0);
		var defs = s.defs, uses = s.uses;
		var isResult = s.isResult;
		// positions
		var pos = 0;
		for (b in f.blocks) {
			b.from = pos;
			pos += 2 * b.ins.length;
			b.to = pos;
			pos += 2;
		}
		start = Scratch.fill(s.start, n, 0x7fffffff);
		end = Scratch.fill(s.end, n, -1);
		fixedFrom = s.fixedFrom;
		fixedTo = s.fixedTo;
		for (k in 0...NPHYS) {
			fixedFrom[k].resize(0);
			fixedTo[k].resize(0);
		}
		var openFixed = s.openFixed;
		var nb = f.blocks.length;
		// per slow-path block: the physical registers with fixed ranges in it
		var fixLo = Scratch.fill(s.fixLo, nb, 0), fixHi = Scratch.fill(s.fixHi, nb, 0);
		for (bi in 0...nb)
			f.blocks[bi].id = bi;
		// per register: the blocks with a use not preceded by a definition in the block (upward-exposed)
		var exposedHead = Scratch.fill(s.exposedHead, n, -1);
		var exposedBlock = s.exposedBlock, exposedNext = s.exposedNext;
		exposedBlock.resize(0);
		exposedNext.resize(0);
		// per block and register: defined in the block (stamped by block),
		// and per register the blocks defining it (a list through defNext)
		var defStamp = Scratch.fill(s.defStamp, n, -1);
		var defHead = Scratch.fill(s.defHead, n, -1);
		var defBlock = s.defBlock, defNext = s.defNext;
		defBlock.resize(0);
		defNext.resize(0);
		// per register and block it appears in: the first and last position
		// (a list through occNext, the latest block first)
		var occHead = Scratch.fill(s.occHead, n, -1);
		var occNext = s.occNext, occBlock = s.occBlock, occFirst = s.occFirst, occLast = s.occLast;
		occNext.resize(0);
		occBlock.resize(0);
		occFirst.resize(0);
		occLast.resize(0);
		// spill costs: the uses and definitions, 8x per loop level
		var weight = s.weight;
		weight.resize(n);
		for (r in 0...n)
			weight[r] = 0;
		// per physical register: the position after its last definition in
		// the block (one from an earlier block is before the block's start)
		for (k in 0...NPHYS)
			openFixed[k] = -1;
		for (bi in 0...nb) {
			var b = f.blocks[bi];
			var p = b.from;
			var cold = b.cold;
			var w:Float = cold ? 0.125 : 1.0;
			for (_ in 0...(b.loopDepth < 6 ? b.loopDepth : 6))
				w *= 8;
			for (i in b.ins) {
				defs.n = 0;
				uses.n = 0;
				t.defsUses(i, defs, uses);
				// a call on a slow path clobbers only its result registers here:
				// what lives across it is saved and restored around it (coldSaves)
				var coldCall = cold && t.isCall(i);
				if (coldCall) coldCalls.push(p);
				var ua = uses.a;
				for (k in 0...uses.n) {
					var r = ua[k];
					if (r >= NPHYS) {
						weight[r] += w;
						var h = occHead[r];
						if (h >= 0 && occBlock[h] == bi) occLast[h] = p else {
							occBlock.push(bi);
							occFirst.push(p);
							occLast.push(p);
							occNext.push(h);
							occHead[r] = occBlock.length - 1;
						}
						if (defStamp[r] != bi) {
							// the first exposed use in this block: record once
							var h = exposedHead[r];
							if (h < 0 || exposedBlock[h] != bi) {
								exposedBlock.push(bi);
								exposedNext.push(h);
								exposedHead[r] = exposedBlock.length - 1;
							}
						}
					} else if (r >= 0) {
						var from = openFixed[r] >= b.from ? openFixed[r] : b.from;
						addFixed(r, from, p);
						if (cold) {
							if (r < 32) fixLo[bi] |= 1 << r else fixHi[bi] |= 1 << (r - 32);
						}
					}
				}
				var da = defs.a;
				for (k in 0...defs.n) {
					var r = da[k];
					if (r >= NPHYS) {
						weight[r] += w;
						var h = occHead[r];
						if (h >= 0 && occBlock[h] == bi) occLast[h] = p + 1 else {
							occBlock.push(bi);
							occFirst.push(p + 1);
							occLast.push(p + 1);
							occNext.push(h);
							occHead[r] = occBlock.length - 1;
						}
						if (defStamp[r] != bi) {
							defStamp[r] = bi;
							defBlock.push(bi);
							defNext.push(defHead[r]);
							defHead[r] = defBlock.length - 1;
						}
					} else if (r >= 0) {
						if (coldCall && !isResult[r]) continue;
						openFixed[r] = p + 1;
						addFixed(r, p + 1, p + 1);
						if (cold) {
							if (r < 32) fixLo[bi] |= 1 << r else fixHi[bi] |= 1 << (r - 32);
						}
					}
				}
				p += 2;
			}
		}
		// live ranges: per register, the blocks it is live into, found by
		// walking back from each exposed use to the definitions; then a range
		// per block it is live in or appears in, adjacent ones merged
		var defines = Scratch.fill(s.defines, nb, -1); // stamped by register
		var liveInSeen = Scratch.fill(s.liveInSeen, nb, -1);
		var liveOutSeen = Scratch.fill(s.liveOutSeen, nb, -1);
		var listed = Scratch.fill(s.listed, nb, -1);
		var occAt = s.occAt;
		occAt.resize(nb);
		var work = s.work;
		var wn = 0;
		var bl = s.bl;
		segAt = Scratch.fill(s.segAt, n, 0);
		segN = Scratch.fill(s.segN, n, 0);
		segFrom = s.segFrom;
		segTo = s.segTo;
		segFrom.resize(0);
		segTo.resize(0);
		var len = Scratch.fill(s.len, n, 0);
		var ptB = s.ptB, ptR = s.ptR;
		ptB.resize(0);
		ptR.resize(0);
		var ptLo = Scratch.fill(s.ptLo, n, 0), ptHi = Scratch.fill(s.ptHi, n, 0);
		var pB = s.pB, pR = s.pR, pA = s.pA, pZ = s.pZ;
		pB.resize(0);
		pR.resize(0);
		pA.resize(0);
		pZ.resize(0);
		var blocks = f.blocks;
		for (r in NPHYS...n) {
			var k = occHead[r];
			if (k < 0) continue;
			var bn = 0;
			while (k >= 0) {
				var bi = occBlock[k];
				occAt[bi] = k;
				listed[bi] = r;
				if (bn == bl.length) bl.push(bi) else bl[bn] = bi;
				bn++;
				k = occNext[k];
			}
			var e = exposedHead[r];
			if (e >= 0) {
				var d = defHead[r];
				while (d >= 0) {
					defines[defBlock[d]] = r;
					d = defNext[d];
				}
				while (e >= 0) {
					var x = exposedBlock[e];
					if (wn == work.length) work.push(x) else work[wn] = x;
					wn++;
					e = exposedNext[e];
				}
				while (wn > 0) {
					var bi = work[--wn];
					if (liveInSeen[bi] == r) continue;
					liveInSeen[bi] = r;
					if (listed[bi] != r) {
						listed[bi] = r;
						occAt[bi] = -1;
						if (bn == bl.length) bl.push(bi) else bl[bn] = bi;
						bn++;
					}
					for (pr in blocks[bi].preds) {
						var pi = pr.id;
						if (liveOutSeen[pi] != r) {
							liveOutSeen[pi] = r;
							if (listed[pi] != r) {
								listed[pi] = r;
								occAt[pi] = -1;
								if (bn == bl.length) bl.push(pi) else bl[bn] = pi;
								bn++;
							}
						}
						if (defines[pi] != r) {
							if (wn == work.length) work.push(pi) else work[wn] = pi;
							wn++;
						}
					}
				}
			}
			// its range in each of those blocks (put in order below)
			var room = 0;
			for (x in 0...bn) {
				var bi = bl[x];
				var b = blocks[bi];
				var o = occAt[bi];
				if (o < 0 && b.cold) {
					// live through a slow path without appearing in it: no range
					// there (slow paths are laid out last: the ranges would cover
					// everything between); the register must only stay unused
					// in that block (ptLo/ptHi, coldBusy)
					ptB.push(bi);
					ptR.push(r);
					ptLo[r] |= fixLo[bi];
					ptHi[r] |= fixHi[bi];
					continue;
				}
				room++;
				pB.push(bi);
				pR.push(r);
				pA.push(liveInSeen[bi] == r || o < 0 ? b.from : occFirst[o]);
				pZ.push(liveOutSeen[bi] == r || o < 0 ? b.to : occLast[o]);
			}
			segN[r] = room; // room for this many, for now
		}
		// the ranges in block order (a counting sort), appended per register
		// in that order, adjacent ones merged
		var np = pB.length;
		var bucket = Scratch.fill(s.bucket, nb + 1, 0);
		for (k in 0...np)
			bucket[pB[k] + 1]++;
		for (k in 0...nb)
			bucket[k + 1] += bucket[k];
		var sorted = Scratch.fill(s.sorted, np, 0);
		for (k in 0...np)
			sorted[bucket[pB[k]]++] = k;
		// the values passing through each slow-path block (ptVal[ptAt[b]...ptAt[b + 1]])
		var ptAt = Scratch.fill(s.ptAt, nb + 1, 0);
		for (bi in ptB)
			ptAt[bi + 1]++;
		for (k in 0...nb)
			ptAt[k + 1] += ptAt[k];
		var ptVal = Scratch.fill(s.ptVal, ptB.length, 0);
		var ptFill = Scratch.fill(s.ptFill, nb, 0);
		for (k in 0...nb)
			ptFill[k] = ptAt[k];
		for (k in 0...ptB.length)
			ptVal[ptFill[ptB[k]]++] = ptR[k];
		var ptBlocks = s.ptBlocks;
		ptBlocks.resize(0);
		for (bi in 0...nb)
			if (ptAt[bi + 1] > ptAt[bi]) ptBlocks.push(bi);
		var room = 0;
		for (r in NPHYS...n) {
			segAt[r] = room;
			room += segN[r];
			segN[r] = 0;
		}
		Scratch.fill(segFrom, room, 0);
		Scratch.fill(segTo, room, 0);
		for (k in sorted) {
			var r = pR[k], a = pA[k], z = pZ[k];
			var m = segAt[r] + segN[r];
			if (segN[r] > 0 && segTo[m - 1] + 2 >= a) {
				len[r] += z - segTo[m - 1];
				segTo[m - 1] = z;
			} else {
				segFrom[m] = a;
				segTo[m] = z;
				segN[r]++;
				len[r] += z - a + 1;
			}
		}
		for (r in NPHYS...n)
			if (segN[r] > 0) {
				start[r] = segFrom[segAt[r]];
				end[r] = segTo[segAt[r] + segN[r] - 1];
			}
		for (r in 0...NPHYS)
			sortFixed(r);
		// linear scan: intervals by start (a counting sort on positions; ties by register)
		var count = Scratch.fill(s.count, pos + 2, 0);
		var live = 0;
		for (r in NPHYS...n)
			if (end[r] >= 0) {
				count[start[r] + 1]++;
				live++;
			}
		for (p in 1...pos + 2)
			count[p] += count[p - 1];
		var order = Scratch.fill(s.order, live, 0);
		for (r in NPHYS...n)
			if (end[r] >= 0) order[count[start[r]]++] = r;
		assigned = Scratch.fill(s.assigned, n, -1);
		for (r in 0...NPHYS)
			assigned[r] = r;
		// per physical register: the ranges of the intervals given it (disjoint,
		// in position order, with their owners)
		for (c in 0...NPHYS) {
			s.oFrom[c].resize(0);
			s.oTo[c].resize(0);
			s.oOwn[c].resize(0);
			s.oPend[c].resize(0);
		}
		var isFpr = s.isFpr;
		var spilled = [];
		var seen = Scratch.fill(s.seen, n, -1); // conflicts found (stamped by query)
		var conflicts = s.conflicts;
		for (r in order) {
			var float = f.floatReg(r);
			var regs = float ? t.fprs : t.gprs;
			var choice = -1;
			// registers r cannot take: fixed in the slow paths it passes
			// through, held by values passing through the slow paths it is in
			coldBusy(r, -1, null);
			var mlo = busyLo, mhi = busyHi;
			inline function masked(c:Int):Bool
				return (c < 32 ? mlo >> c : mhi >> (c - 32)) & 1 != 0;
			var h = f.hint(r);
			if (h >= 0) {
				var hr = h < NPHYS ? h : assigned[h];
				if (hr >= 0 && isFpr[hr] == (float ? 1 : 2) && !masked(hr) && free(hr, r)) choice = hr;
			}
			if (choice < 0)
				for (c in regs)
					if (!masked(c) && free(c, r)) {
						choice = c;
						break;
					}
			if (choice < 0) {
				// the register whose overlapping intervals cost least to spill
				// (weight per position covered), if less than this one
				var best = -1;
				var bestCost = r >= noSpillFrom ? 1e300 : lateRound ? -1.0 : weight[r] / len[r];
				for (c in regs) {
					if (masked(c) || fixedOverlapSegs(c, r)) continue;
					var cost = 0.0;
					var ok = true;
					conflicting(c, r, seen, conflicts);
					for (a in conflicts) {
						if (a >= noSpillFrom) {
							ok = false;
							break;
						}
						cost += weight[a] / len[a];
					}
					if (ok && cost < bestCost) {
						best = c;
						bestCost = cost;
					}
				}
				var evictPassing = false;
				if (best < 0 && r >= noSpillFrom) {
					// spill code in a slow path: a register held by values
					// passing through it is taken from them
					for (c in regs) {
						if ((c < 32 ? ptLo[r] >> c : ptHi[r] >> (c - 32)) & 1 != 0 || fixedOverlapSegs(c, r)) continue;
						var ok = true;
						conflicting(c, r, seen, conflicts);
						coldBusy(r, c, conflicts);
						for (a in conflicts)
							if (a >= noSpillFrom) ok = false;
						if (ok) {
							best = c;
							evictPassing = true;
							break;
						}
					}
				}
				if (best < 0) {
					if (r >= noSpillFrom) throw "hxmc: out of registers in " + f.name;
					spilled.push(r);
					continue;
				}
				conflicting(best, r, seen, conflicts);
				if (evictPassing) coldBusy(r, best, conflicts);
				for (a in conflicts) {
					assigned[a] = -1;
					spilled.push(a);
					seen[a] = -2; // evicted: its ranges leave the register
				}
				// (the ranges ending before r starts are never asked about
				// again: those of the evicted intervals stay, unseen)
				var of = s.oFrom[best], ot = s.oTo[best], oo = s.oOwn[best];
				var k = firstEnding(ot, segFrom[segAt[r]]);
				for (x in k...of.length)
					if (seen[oo[x]] != -2) {
						of[k] = of[x];
						ot[k] = ot[x];
						oo[k] = oo[x];
						k++;
					}
				of.resize(k);
				ot.resize(k);
				oo.resize(k);
				var pd = s.oPend[best];
				k = 0;
				for (x in 0...pd.length)
					if (seen[pd[x]] != -2) pd[k++] = pd[x];
				pd.resize(k);
				choice = best;
			}
			assigned[r] = choice;
			occupy(choice, r);
		}
		return spilled;
	}

	var busyLo = 0;
	var busyHi = 0;

	// the registers held by values passing through the slow-path blocks r
	// has ranges in (busyLo/busyHi); with want >= 0, the values holding
	// register want there, added to out
	function coldBusy(r:Int, want:Int, out:Array<Int>) {
		busyLo = 0;
		busyHi = 0;
		var pbs = s.ptBlocks;
		var npb = pbs.length;
		if (npb == 0) return;
		var blocks = f.blocks;
		if (end[r] < blocks[pbs[0]].from) return;
		var ptAt = s.ptAt, ptVal = s.ptVal;
		var j = segAt[r];
		for (k in j...j + segN[r]) {
			var x = segFrom[k], y = segTo[k];
			// the first of those blocks ending at or after x
			var lo = 0, hi = npb;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (blocks[pbs[mid]].to < x) lo = mid + 1 else hi = mid;
			}
			while (lo < npb && blocks[pbs[lo]].from <= y) {
				var bi = pbs[lo];
				for (q in ptAt[bi]...ptAt[bi + 1]) {
					var v = ptVal[q];
					var a = assigned[v];
					if (a < 0 || v == r) continue;
					if (a < 32) busyLo |= 1 << a else busyHi |= 1 << (a - 32);
					if (a == want && out.indexOf(v) < 0) out.push(v);
				}
				lo++;
			}
		}
	}

	// the first range of physical register c ending at or after x
	inline function firstEnding(ot:Array<Int>, x:Int):Int {
		var lo = 0, hi = ot.length;
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (ot[mid] < x) lo = mid + 1 else hi = mid;
		}
		return lo;
	}

	// whether physical register c can take interval r: no fixed range and no
	// range of an interval given it overlaps r's
	function free(c:Int, r:Int):Bool {
		if (fixedOverlapSegs(c, r)) return false;
		var j = segAt[r];
		var pd = s.oPend[c];
		if (pd.length > 0) {
			var rs = segFrom[j];
			for (a in pd)
				if (end[a] >= rs && overlaps(a, r)) return false;
		}
		var of = s.oFrom[c], ot = s.oTo[c];
		var no = of.length;
		if (no == 0) return true;
		// common: everything there ends before r starts
		if (ot[no - 1] < segFrom[j]) return true;
		for (k in j...j + segN[r]) {
			var x = segFrom[k], y = segTo[k];
			var i = firstEnding(ot, x);
			if (i < no && of[i] <= y) return false;
		}
		return true;
	}

	// the intervals given physical register c that overlap r, into out
	var stamp = 0;

	function conflicting(c:Int, r:Int, seen:Array<Int>, out:Array<Int>) {
		out.resize(0);
		var st = ++stamp;
		var of = s.oFrom[c], ot = s.oTo[c], oo = s.oOwn[c];
		var no = of.length;
		var j = segAt[r];
		var rs = segFrom[j];
		for (a in s.oPend[c])
			if (end[a] >= rs && seen[a] != st && overlaps(a, r)) {
				seen[a] = st;
				out.push(a);
			}
		for (k in j...j + segN[r]) {
			var x = segFrom[k], y = segTo[k];
			var i = firstEnding(ot, x);
			while (i < no && of[i] <= y) {
				var a = oo[i];
				if (seen[a] != st) {
					seen[a] = st;
					out.push(a);
				}
				i++;
			}
		}
	}

	// gives r's ranges to physical register c: appended to its ordered list
	// when they all come after it, else kept pending (whole intervals, merged
	// in batches: intervals come by start, a merge moves every range after
	// the merged ones, and one per interval made allocation quadratic with
	// intervals with holes)
	static inline var PEND = 16;

	function occupy(c:Int, r:Int) {
		var of = s.oFrom[c], ot = s.oTo[c], oo = s.oOwn[c];
		var j = segAt[r], je = j + segN[r];
		var no = of.length;
		var pd = s.oPend[c];
		var x0 = segFrom[j];
		if (pd.length == 0 && (no == 0 || of[no - 1] < x0)) {
			for (k in j...je) {
				of.push(segFrom[k]);
				ot.push(segTo[k]);
				oo.push(r);
			}
			return;
		}
		// pending intervals that ended before r starts are never asked about
		// again (later queries start later): dropped
		var k = 0;
		for (a in pd)
			if (end[a] >= x0) pd[k++] = a;
		pd.resize(k);
		pd.push(r);
		if (pd.length < PEND) return;
		// the pending ranges, by start
		var ps = s.pendSeg, po = s.pendOwn, idx = s.pendIdx;
		ps.resize(0);
		po.resize(0);
		idx.resize(0);
		for (a in pd)
			for (q in segAt[a]...segAt[a] + segN[a]) {
				idx.push(ps.length);
				ps.push(q);
				po.push(a);
			}
		pd.resize(0);
		var sf = segFrom;
		idx.sort((p, q) -> sf[ps[p]] - sf[ps[q]]);
		var np = idx.length;
		// the listed ranges from the first pending one on move up: merged
		var lo = 0, hi = no;
		x0 = sf[ps[idx[0]]];
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (of[mid] < x0) lo = mid + 1 else hi = mid;
		}
		var i0 = lo;
		var nt = no - i0;
		var mf = s.mFrom, mt = s.mTo, mo = s.mOwn;
		if (mf.length < nt) {
			mf.resize(nt);
			mt.resize(nt);
			mo.resize(nt);
		}
		for (q in 0...nt) {
			mf[q] = of[i0 + q];
			mt[q] = ot[i0 + q];
			mo[q] = oo[i0 + q];
		}
		for (_ in 0...np) {
			of.push(0);
			ot.push(0);
			oo.push(0);
		}
		var w = i0, i = 0, k = 0;
		while (i < nt || k < np) {
			if (k >= np || i < nt && mf[i] < sf[ps[idx[k]]]) {
				of[w] = mf[i];
				ot[w] = mt[i];
				oo[w] = mo[i];
				i++;
			} else {
				var p = idx[k];
				of[w] = sf[ps[p]];
				ot[w] = segTo[ps[p]];
				oo[w] = po[p];
				k++;
			}
			w++;
		}
	}

	// whether intervals a and r overlap (r starts after a: a's ranges that
	// end before r starts are skipped by a binary search)
	function overlaps(a:Int, r:Int):Bool {
		var i = segAt[a], ie = i + segN[a], j = segAt[r], je = j + segN[r];
		var rs = segFrom[j];
		if (ie - i > 4) {
			var hi = ie;
			while (i < hi) {
				var mid = (i + hi) >> 1;
				if (segTo[mid] < rs) i = mid + 1 else hi = mid;
			}
		}
		while (i < ie && j < je) {
			if (segTo[i] < segFrom[j]) i++ else if (segTo[j] < segFrom[i]) j++ else return true;
		}
		return false;
	}

	function fixedOverlapSegs(c:Int, r:Int):Bool {
		if (fixedFrom[c].length == 0) return false;
		var j = segAt[r];
		for (k in j...j + segN[r])
			if (fixedOverlap(c, segFrom[k], segTo[k])) return true;
		return false;
	}

	var coldCalls:Array<Int> = []; // positions of the calls in cold blocks (the last round's)

	// Saves the caller-saved registers live across each slow-path call into
	// frame slots before it and reloads them after it (allocate let values
	// stay in such registers across those calls).
	function coldSaves() {
		var nc = coldCalls.length;
		if (nc == 0) return;
		// per call: the registers held by values live across it (a range
		// starting before and ending after it), bucketed by call
		var pairCall:Array<Int> = [], pairReg:Array<Int> = [];
		for (r in NPHYS...f.nregs) {
			var a = assigned[r];
			if (a < 0 || end[r] < 0) continue;
			for (k in segAt[r]...segAt[r] + segN[r]) {
				var x = segFrom[k], y = segTo[k];
				if (y - x < 3) continue;
				// the first call at or after x (a range starting at a call:
				// live into a block the call begins, or read by the call; one
				// a definition starts begins after the instruction)
				var lo = 0, hi = nc;
				while (lo < hi) {
					var mid = (lo + hi) >> 1;
					if (coldCalls[mid] < x) lo = mid + 1 else hi = mid;
				}
				while (lo < nc && coldCalls[lo] + 1 < y) {
					pairCall.push(lo);
					pairReg.push(a);
					lo++;
				}
			}
		}
		var at = Arrays.filled(nc + 1, 0);
		for (c in pairCall)
			at[c + 1]++;
		for (k in 0...nc)
			at[k + 1] += at[k];
		var saved = Arrays.filled(pairCall.length, 0);
		var fill = at.copy();
		for (k in 0...pairCall.length)
			saved[fill[pairCall[k]]++] = pairReg[k];
		var slotOf = Arrays.filled(NPHYS, -1);
		var defs = s.defs, uses = s.uses;
		var clobbered = Arrays.filled(NPHYS, -1); // stamped by call
		var ptAt = s.ptAt, ptVal = s.ptVal;
		var ci = 0;
		for (b in f.blocks) {
			if (!b.cold) continue;
			var c0 = ci;
			while (ci < nc && coldCalls[ci] < b.to)
				ci++;
			var pt0 = ptAt[b.id], pt1 = ptAt[b.id + 1];
			if (ci == c0 && pt0 == pt1) continue;
			// what the block writes of the registers of values passing through
			// it: its fixed registers and what its calls clobber; those values
			// are saved at its start and restored before its branch
			var clo = s.fixLo[b.id], chi = s.fixHi[b.id];
			var p = b.from;
			var k = c0;
			for (ins in b.ins) {
				if (k < ci && coldCalls[k] == p) {
					defs.n = 0;
					uses.n = 0;
					t.defsUses(ins, defs, uses);
					for (q in 0...defs.n) {
						var d = defs.a[q];
						if (d >= 0 && d < NPHYS && !s.isResult[d]) {
							if (d < 32) clo |= 1 << d else chi |= 1 << (d - 32);
						}
					}
					k++;
				}
				p += 2;
			}
			var whole = [];
			for (q in pt0...pt1) {
				var a = assigned[ptVal[q]];
				if (a < 0 || (a < 32 ? clo >> a : chi >> (a - 32)) & 1 == 0 || whole.indexOf(a) >= 0) continue;
				whole.push(a);
			}
			var out = [];
			for (a in whole) {
				if (slotOf[a] < 0) slotOf[a] = f.slot(8, 8);
				out.push(t.spillStore(slotOf[a], a, a >= f.fprBase));
			}
			// around each call: the values with ranges across it
			p = b.from;
			k = c0;
			for (ins in b.ins) {
				if (k < ci && coldCalls[k] == p) {
					defs.n = 0;
					uses.n = 0;
					t.defsUses(ins, defs, uses);
					for (q in 0...defs.n) {
						var d = defs.a[q];
						if (d >= 0 && d < NPHYS && !s.isResult[d]) clobbered[d] = k;
					}
					var after = [];
					for (q in at[k]...at[k + 1]) {
						var a = saved[q];
						if (clobbered[a] != k || whole.indexOf(a) >= 0) continue;
						if (slotOf[a] < 0) slotOf[a] = f.slot(8, 8);
						out.push(t.spillStore(slotOf[a], a, a >= f.fprBase));
						after.push(t.spillLoad(a, slotOf[a], a >= f.fprBase));
					}
					out.push(ins);
					for (x in after)
						out.push(x);
					k++;
				} else out.push(ins);
				p += 2;
			}
			if (whole.length > 0) {
				var e = out.length;
				while (e > 0 && t.isBranch(out[e - 1]))
					e--;
				var restores = [for (a in whole) t.spillLoad(a, slotOf[a], a >= f.fprBase)];
				out = out.slice(0, e).concat(restores).concat(out.slice(e));
			}
			b.ins = out;
		}
	}

	function addFixed(r:Int, from:Int, to:Int) {
		var fr = fixedFrom[r], tr = fixedTo[r];
		var n = fr.length;
		if (n > 0 && fr[n - 1] == from) {
			if (tr[n - 1] < to) tr[n - 1] = to;
			return;
		}
		fr.push(from);
		tr.push(to);
	}

	// the ranges are recorded in position order (blocks in layout order,
	// instructions in order): no sorting needed
	function sortFixed(r:Int) {
		// a running maximum of the ends, so a binary search finds overlaps
		var m = -1;
		var ft = fixedTo[r];
		for (i in 0...ft.length) {
			if (ft[i] < m) ft[i] = m;
			m = ft[i];
		}
	}

	// whether physical register r has a fixed range overlapping [a, b]
	function fixedOverlap(r:Int, a:Int, b:Int):Bool {
		var fr = fixedFrom[r], tr = fixedTo[r];
		// first range whose (running max) end >= a
		var lo = 0, hi = fr.length;
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (tr[mid] < a) lo = mid + 1 else hi = mid;
		}
		while (lo < fr.length && fr[lo] <= b) {
			if (fr[lo] <= b && fixedEnd(r, lo) >= a) return true;
			lo++;
		}
		return false;
	}

	inline function fixedEnd(r:Int, i:Int):Int
		return fixedTo[r][i];

	// ---- spill code

	function insertSpills(spilled:Array<Int>) {
		var slotOf = hxmc.Lir.Arrays.filled(f.nregs, -1);
		for (r in spilled)
			slotOf[r] = f.slot(8, 8);
		var defs = new RegList(), uses = new RegList();
		// per instruction: spilled register -> its temporary (stamped by instruction)
		var tmp = hxmc.Lir.Arrays.filled(f.nregs, -1);
		var tmpStamp = hxmc.Lir.Arrays.filled(f.nregs, -1);
		var stamp = 0;
		var nOld = f.nregs;
		if (noSpillFrom > nOld) noSpillFrom = nOld;
		for (b in f.blocks) {
			var out = [];
			var any = false;
			for (i in b.ins) {
				defs.n = 0;
				uses.n = 0;
				t.defsUses(i, defs, uses);
				stamp++;
				var mapped = false;
				for (k in 0...uses.n) {
					var r = uses.a[k];
					if (r < nOld && slotOf[r] >= 0 && tmpStamp[r] != stamp) {
						var nr = f.newReg(f.floatReg(r));
						tmp[r] = nr;
						tmpStamp[r] = stamp;
						mapped = true;
						out.push(t.spillLoad(nr, slotOf[r], f.floatReg(r)));
					}
				}
				var stores = null;
				for (k in 0...defs.n) {
					var r = defs.a[k];
					if (r < nOld && slotOf[r] >= 0) {
						if (tmpStamp[r] != stamp) {
							var nr = f.newReg(f.floatReg(r));
								tmp[r] = nr;
							tmpStamp[r] = stamp;
							mapped = true;
						}
						if (stores == null) stores = [];
						stores.push(t.spillStore(slotOf[r], tmp[r], f.floatReg(r)));
					}
				}
				if (mapped) {
					var st = stamp;
					rename(i, r -> r < nOld && tmpStamp[r] == st ? tmp[r] : r);
					any = true;
				}
				out.push(i);
				if (stores != null)
					for (s in stores)
						out.push(s);
			}
			if (any || out.length != b.ins.length) b.ins = out;
		}
		// the hints of spilled registers no longer apply
		for (r in spilled)
			f.setHint(r, -1);
	}

	public static function rename(i:LIns, m:Int->Int) {
		if (i.d >= NPHYS) i.d = m(i.d);
		if (i.s1 >= NPHYS) i.s1 = m(i.s1);
		if (i.s2 >= NPHYS) i.s2 = m(i.s2);
		if (i.s3 >= NPHYS) i.s3 = m(i.s3);
		if (i.base >= NPHYS) i.base = m(i.base);
		if (i.index >= NPHYS) i.index = m(i.index);
	}

	function rewrite() {
		for (b in f.blocks)
			for (i in b.ins) {
				rename(i, r -> {
					var a = assigned[r];
					if (a < 0) throw "hxmc: unallocated register " + r + " in " + f.name;
					a;
				});
				for (r in [i.d, i.s1, i.s2, i.s3, i.base, i.index])
					if (r >= 0 && r < NPHYS) usedRegs[r] = true;
			}
	}
}
