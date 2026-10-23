package hxmc;

import haxe.ds.Vector;
import hxmc.Mir;
import core.ds.VectorTools.vector;

// SSA construction on a finished graph (Braun et al.), for the passes that
// turn memory into values (Escape, Sroa; MirBuild builds its own SSA as it
// goes, sealing blocks): a variable's value at block entries, on demand.
// The definition at the end of a block (ends, by block number: NONE; LAZY:
// made by endOf on first use and kept), else a phi where predecessors meet
// (made by mkPhi, its operands set by setArgs in finish), else the entry's
// value (undef; LAZY: made by undefOf on first use). Iterative: no recursion
// along long paths, nor through the phis' operands. memo: by block number,
// NOTSET (reset puts it back).
//
// The phis' operands are read in finish: the phi made last first, all of
// its operands, then the phis those made (depthFirst false), or each
// operand down to its own phis' operands before the next operand, as a
// recursive reader would (depthFirst true). Each order makes the same
// values; the order in which phis (and lazy values) are made is what
// differs.
class SsaReader {
	public static inline var NONE = -3;
	public static inline var NOTSET = -4;
	public static inline var LAZY = -5;

	public var ends:Vector<Int>;
	public var depthFirst = false;
	public var endOf:Null<MBlock->Int>;
	public var undefOf:Null<() -> Int>;

	var memo:Vector<Int>;
	var touched:Array<Int> = [];
	var entry:MBlock;
	var undef:Int;
	var mkPhi:MBlock->Int;
	var setArgs:(Int, Vector<Int>) -> Void;
	// the phis whose operands are to read: value, block (depthFirst: the
	// next operand, the operands read)
	var pendV:Array<Int> = [];
	var pendB:Array<MBlock> = [];
	var pendQ:Array<Int> = [];
	var pendA:Array<Vector<Int>> = [];
	var npend = 0;

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

	inline function endValue(b:MBlock):Int {
		var d = ends[b.id];
		if (d == LAZY) {
			d = endOf(b);
			ends[b.id] = d;
		}
		return d;
	}

	inline function undefValue():Int {
		if (undef == LAZY) undef = undefOf();
		return undef;
	}

	public inline function readEnd(b:MBlock):Int {
		var d = endValue(b);
		return d != NONE ? d : readEntry(b);
	}

	public function readEntry(b:MBlock):Int {
		var chain:Array<MBlock> = [];
		var r = NONE;
		var n = 0;
		while (true) {
			var m = memo[b.id];
			if (m != NOTSET) {
				r = m;
				break;
			}
			if (b == entry || b.preds.length == 0 || n++ > 1000000) {
				r = undefValue();
				remember(b, r);
				break;
			}
			if (b.preds.length == 1) {
				chain.push(b);
				var p = b.preds[0];
				var d = endValue(p);
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
			pendB[npend] = b;
			if (depthFirst) {
				pendQ[npend] = 0;
				pendA[npend] = new Vector<Int>(b.preds.length);
			}
			npend++;
			break;
		}
		for (x in chain)
			remember(x, r);
		return r;
	}

	public function finish() {
		if (depthFirst) {
			while (npend > 0) {
				var top = npend - 1;
				var b = pendB[top], args = pendA[top], q = pendQ[top];
				if (q == args.length) {
					npend--;
					setArgs(pendV[top], args);
					pendA[top] = null;
					continue;
				}
				pendQ[top] = q + 1;
				// (a phi made here is read next, then this one goes on)
				args[q] = readEnd(b.preds[q]);
			}
			return;
		}
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

class Ssa {
	// the phis made (SsaReader) whose operands are one value (or the phi
	// itself), through copies, become copies of it (to a fixed point)
	public static function trivialPhis(vals:Array<MIns>, phis:Array<MIns>) {
		var changed = true;
		while (changed) {
			changed = false;
			for (p in phis) {
				if (p.op != Phi || p.dead) continue;
				var same = -1, trivial = true;
				for (a in p.args) {
					var x = a;
					while (vals[x].op == Copy && vals[x].a >= 0)
						x = vals[x].a;
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
