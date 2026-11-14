package hxmc;

import haxe.ds.Vector;
import hxmc.Mir;
import hxmc.Ssa;
import hxmc.ir.Ir.Ty;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Loop versioning of Array reads (object-level Mir, before Opt): a counted
// loop whose Array reads are of arrays it cannot change, at its counter or
// at a value it does not change, gets a copy where they read the element
// directly (OInfo.prechecked: no kind or bounds test, no slow path), entered
// when a test before the loop finds every such array not null, of the kind
// its reads expect, and long enough for the counter's range; else the loop
// as it was runs. In the copy an Array read writes no memory (Opt.objKill:
// a reference read's slow path may box, a collection, so it otherwise
// writes every class), so what the loop reads again each time (the field
// the array is in, its header) moves out of it (Opt.licm).
//
// The loops taken (the narrow case):
//  - a header with the counter, a phi of a start from the one block before
//    the loop and of counter + 1 from the one block that goes back to it,
//    and the loop's only exit, a branch on counter < limit (or >=), the
//    limit computed before the loop;
//  - nothing in the loop that may collect, call or change an array's
//    length or kind: arithmetic, comparisons, field reads and writes
//    (not of a field an array the loop reads is in), Array and NativeArray
//    reads, NativeArray writes, null tests, the inline conversions;
//  - Array reads at the counter, after the exit test (not in the header),
//    or at a value from before the loop; of an array from before the loop
//    or read from a field of an object from before the loop (the copy reads
//    it in the test before the loop).
typedef Arr = {key:String, a:Int, obj:Int, field:Null<MIns>};

class LoopVersion {
	// at most this many instructions in a loop copied
	static inline var MAX_SIZE = 400;
	// at most this many loops copied per function
	static inline var MAX_LOOPS = 8;
	// the largest step and look-ahead of a counter (counter + them stays below 2^31: an array is shorter)
	static inline var MAX_STEP = 16;

	var f:MFunc;
	var done = new Map<Int, Bool>(); // headers (of originals and copies) already looked at

	public var versioned = 0;

	public function new(f:MFunc)
		this.f = f;

	public function run() {
		if (f.allRegs) return;
		for (_ in 0...MAX_LOOPS)
			if (!one()) break;
	}

	inline function v(id:Int):MIns
		return f.vals[id];

	function newBlock():MBlock {
		var id = 0;
		for (b in f.blocks)
			if (b.id >= id) id = b.id + 1;
		var b = new MBlock(id);
		b.sealed = b.filled = true;
		f.blocks.push(b);
		return b;
	}

	function add(b:MBlock, op:Op, ty:MTy):MIns {
		var x = new MIns(op, ty);
		x.id = f.vals.length;
		f.vals.push(x);
		x.block = b;
		b.ins.push(x);
		return x;
	}

	// one loop versioned (false: none left)
	function one():Bool {
		var cfg = f.cfg();
		cfg.loops();
		if (cfg.irreducible) return false;
		var order = cfg.rpo;
		var bodies = cfg.loopBodies();
		var k = order.length;
		while (k-- > 1) { // inner loops first
			var h = order[k];
			var ks = bodies[k];
			if (ks == null || done.exists(h.id)) continue;
			done.set(h.id, true);
			var members = [for (x in ks) order[x]];
			if (try1(h, members, cfg)) {
				f.edited();
				versioned++;
				return true;
			}
		}
		return false;
	}

	// an array the copy reads (or whose length is the limit): a value from
	// before the loop, or read from a field of an object from before the loop
	// that the loop does not write (the copy reads it before the loop)
	function arrayOf(id:Int, inLoop:Null<MBlock>->Bool, fieldsWritten:Map<Int, Bool>):Null<Arr> {
		var a = v(id);
		if (!inLoop(a.block)) return {key: "v" + id, a: id, obj: -1, field: null};
		if (a.op == GetField && !inLoop(v(a.a).block) && !fieldsWritten.exists(fieldKey(a.info)) && a.info.t.match(TRef(_)))
			return {key: "f" + a.a + ":" + fieldKey(a.info), a: id, obj: a.a, field: a};
		return null;
	}

	function try1(h:MBlock, members:Array<MBlock>, cfg:Cfg<MBlock>):Bool {
		var inL = new Map<Int, Bool>();
		for (b in members) {
			if (b.handler) return false;
			inL.set(b.id, true);
		}
		function inLoop(b:Null<MBlock>):Bool
			return b != null && inL.exists(b.id);
		inline function outside(id:Int):Bool
			return id >= 0 && !inLoop(v(id).block);
		// one way in, one way back
		if (h.preds.length != 2) return false;
		var pre = -1, latch = -1;
		for (k in 0...2)
			if (inLoop(h.preds[k])) latch = k else pre = k;
		if (pre < 0 || latch < 0) return false;
		// the header's branch, one of its edges out of the loop (others may leave too: breaks)
		var t = h.term();
		if (t == null || t.op != Br) return false;
		var exitK = -1;
		for (k in 0...2)
			if (!inLoop(t.targets[k])) {
				if (exitK >= 0) return false;
				exitK = k;
			}
		if (exitK < 0) return false;
		var exitB = t.targets[exitK];
		if (exitB == t.targets[1 - exitK]) return false;
		// what the loop does
		var size = 0;
		var gets:Array<MIns> = [];
		var fieldsWritten = new Map<Int, Bool>();
		for (b in members)
			for (i in b.ins) {
				if (i.dead) continue;
				size++;
				if (i.info != null && i.info.cold) return false;
				switch i.op {
					case Const | ConstF | SymAddr | Copy | Phi | Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Neg | Not | Div | Rem | UDiv | URem | Rotr | FAdd | FSub | FMul | FDiv | FNeg | FSqrt | FAbs | Cmp | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits | Select | Load | TlsLoad | Jmp | Br | Switch:
					case NullCheck | GetField | FieldAddr | EnumTag | TypeTest | ArrayLength | NArrayLength | NArrayGet | NArraySet:
					case SetField:
						fieldsWritten.set(fieldKey(i.info), true);
					case ArrayGet:
						gets.push(i);
					case Call if (i.sym != null && StringTools.startsWith(i.sym, MirBuild.SPECIAL) && !StringTools.startsWith(i.sym, MirBuild.SPECIAL + "atomic")):
					case _:
						return false;
				}
			}
		if (size > MAX_SIZE || gets.length == 0) return false;
		// the test: counter < limit to stay (cmp lt), counter >= limit to leave (cmp ge)
		var c = v(t.a);
		if (c.op != Cmp || c.block != h) return false;
		var iv = -1, limit = -1;
		if (c.imm == (CLt : Int) && exitK == 1 || c.imm == (CGe : Int) && exitK == 0) {
			iv = c.a;
			limit = c.b;
		} else if (c.imm == (CGt : Int) && exitK == 1 || c.imm == (CLe : Int) && exitK == 0) {
			iv = c.b;
			limit = c.a;
		} else
			return false;
		// (the test may be of counter + c, c a small constant: the body then
		// runs while counter + c < limit, so counter + d is in range for d <= c)
		var ahead = 0;
		{
			var x = v(iv);
			if (x.op == Add && x.block == h && constOf(x.b) != null) {
				ahead = constOf(x.b);
				if (ahead < 0 || ahead > MAX_STEP) return false;
				iv = x.a;
			}
		}
		var phi = v(iv);
		if (phi.op != Phi || phi.block != h || phi.ty != I32 || phi.args.length != 2 || v(limit).ty != I32) return false;
		// the limit: from before the loop, or an array's length the loop cannot change
		var limitArr:Null<Arr> = null;
		if (!outside(limit)) {
			var l = v(limit);
			if (l.op != ArrayLength) return false;
			limitArr = arrayOf(l.a, inLoop, fieldsWritten);
			if (limitArr == null) return false;
		}
		var start = phi.args[pre], next = v(phi.args[latch]);
		var step = next.op == Add && next.a == iv && inLoop(next.block) ? constOf(next.b) : null;
		if (step == null || step < 1 || step > MAX_STEP) return false;
		// the reads the copy takes: their arrays, and the indices they need
		var arrays:Array<{arr:Arr, kind:Int, upto:Bool, idx:Array<Int>}> = [];
		var taken:Array<MIns> = [];
		for (g in gets) {
			var off = offsetOf(g.b, iv, ahead);
			var idxOk = off != null && g.block != h || outside(g.b);
			if (!idxOk) continue;
			var arr = arrayOf(g.a, inLoop, fieldsWritten);
			if (arr == null) continue;
			var kind = MemLower.arrKind(g.info.t);
			var found = null;
			for (e in arrays)
				if (e.arr.key == arr.key) found = e;
			if (found != null && found.kind != kind) continue;
			if (found == null) {
				found = {arr: arr, kind: kind, upto: false, idx: []};
				arrays.push(found);
			}
			if (off != null) found.upto = true else if (found.idx.indexOf(g.b) < 0) found.idx.push(g.b);
			taken.push(g);
		}
		if (taken.length == 0) return false;
		// (a reference read left with its slow path writes everything: no gain then)
		for (g in gets)
			if (taken.indexOf(g) < 0 && Opt.ptrElem(g.info.t)) return false;
		version(h, members, inLoop, cfg, pre, start, limit, limitArr, arrays, taken);
		return true;
	}

	static function fieldKey(o:OInfo):Int
		return Opt.fieldOff(o);

	// the value of an I32 constant (null: not one)
	function constOf(id:Int):Null<Int> {
		var x = v(id);
		return x.op == Const && x.sym == null && x.ty == I32 ? x.imm : null;
	}

	// an index at counter + d, 0 <= d <= ahead: d (null: not one)
	function offsetOf(id:Int, iv:Int, ahead:Int):Null<Int> {
		if (id == iv) return 0;
		var x = v(id);
		if (x.op != Add || x.a != iv) return null;
		var d = constOf(x.b);
		return d != null && d >= 0 && d <= ahead ? d : null;
	}

	function version(h:MBlock, members:Array<MBlock>, inLoop:Null<MBlock>->Bool, cfg:Cfg<MBlock>, pre:Int, start:Int, limit:Int, limitArr:Null<Arr>,
			arrays:Array<{arr:Arr, kind:Int, upto:Bool, idx:Array<Int>}>, taken:Array<MIns>) {
		var preB = h.preds[pre];
		// (dominance in the loop, before the edits: the copy's is the same)
		var oldIndex = new Map<Int, Int>();
		for (b in members)
			oldIndex.set(b.id, cfg.index(b));
		// ---- the test before the loop: blocks failing to slow, which enters the loop as it was
		var slow = newBlock();
		var gb = newBlock();
		var first = gb;
		function test(cond:Int) {
			// cond != 0 goes on; else slow
			var br = add(gb, Br, Void);
			br.a = cond;
			var next = newBlock();
			br.targets = vector(next, slow);
			gb.succs = [next, slow];
			next.preds = [gb];
			slow.preds.push(gb);
			gb = next;
		}
		function cmp(c:Cond, a:Int, b:Int):Int {
			var x = add(gb, Cmp, I32);
			x.imm = c;
			x.a = a;
			x.b = b;
			return x.id;
		}
		function iconst(k:Int):Int {
			var x = add(gb, Const, I32);
			x.imm = k;
			return x.id;
		}
		function lzero():Int
			return add(gb, Const, I64).id;
		// the arrays as before the loop (not null), by key
		var before = new Map<String, Int>();
		function arrayBefore(e:Arr):Int {
			var a = before.get(e.key);
			if (a != null) return a;
			a = e.a;
			if (e.field != null) {
				test(cmp(CNe, e.obj, lzero()));
				var gf = add(gb, GetField, I64);
				gf.a = e.obj;
				gf.info = e.field.info.copy(null);
				gf.vty = e.field.vty;
				gf.pos = e.field.pos;
				a = gf.id;
			}
			test(cmp(CNe, a, lzero()));
			before.set(e.key, a);
			return a;
		}
		function lengthOf(a:Int):Int {
			var len = add(gb, ArrayLength, I32);
			len.a = a;
			len.info = new OInfo();
			return len.id;
		}
		// the start is not negative (the counter only grows from it)
		test(cmp(CGe, start, iconst(0)));
		var lim = limitArr == null ? limit : lengthOf(arrayBefore(limitArr));
		for (e in arrays) {
			var a = arrayBefore(e.arr);
			var kind = add(gb, Load, I32);
			kind.a = a;
			kind.imm = 4;
			kind.imm2 = 1;
			kind.size = 4;
			kind.mem = Opt.MHdr;
			test(cmp(CEq, kind.id, iconst(e.kind)));
			var len = lengthOf(a);
			if (e.upto) test(cmp(CLe, lim, len));
			for (x in e.idx)
				test(cmp(CULt, x, len));
		}
		// gb: every test passed, into the copy
		// ---- the loop's blocks copied
		var bmap = new Map<Int, MBlock>();
		for (b in members) {
			var nb = newBlock();
			nb.cold = b.cold;
			bmap.set(b.id, nb);
		}
		inline function mb(b:MBlock):MBlock
			return inLoop(b) ? bmap.get(b.id) : b;
		var vmap = new Map<Int, Int>();
		for (b in members)
			for (i in b.ins) {
				if (i.dead) continue;
				var x = new MIns(i.op, i.ty);
				x.id = f.vals.length;
				f.vals.push(x);
				vmap.set(i.id, x.id);
			}
		inline function m(id:Int):Int {
			var r = id < 0 ? null : vmap.get(id);
			return r == null ? id : r;
		}
		// the edges out of the loop, before the edits (from, to)
		var exits:Array<{from:MBlock, to:MBlock}> = [];
		for (b in members)
			for (s in b.succs)
				if (!inLoop(s)) exits.push({from: b, to: s});
		for (b in members) {
			var nb = bmap.get(b.id);
			for (i in b.ins) {
				if (i.dead) continue;
				var x = f.vals[vmap.get(i.id)];
				x.a = m(i.a);
				x.b = m(i.b);
				x.c = m(i.c);
				x.imm = i.imm;
				x.imm2 = i.imm2;
				x.vty = i.vty;
				if (i.info != null) {
					x.info = i.info.copy(i.info.cont == null ? null : mb(i.info.cont));
					if (i.op == ArrayGet && taken.indexOf(i) >= 0) x.info.prechecked = true;
				}
				x.pos = i.pos;
				x.f = i.f;
				x.size = i.size;
				x.signed = i.signed;
				x.sym = i.sym;
				x.mem = i.mem;
				x.release = i.release;
				x.noReturn = i.noReturn;
				x.returnsTwice = i.returnsTwice;
				x.keepsFrame = i.keepsFrame;
				x.variadic = i.variadic;
				x.argTys = i.argTys;
				x.cCall = i.cCall;
				x.cSizes = i.cSizes;
				x.cGroups = i.cGroups;
				x.structRet = i.structRet;
				x.cRet = i.cRet;
				x.cases = i.cases;
				x.args = i.args.map(a -> m(a));
				x.targets = i.targets.map(t -> mb(t));
				x.block = nb;
				nb.ins.push(x);
			}
			nb.succs = [for (s in b.succs) mb(s)];
			nb.preds = [for (p in b.preds) mb(p)];
		}
		var h2 = bmap.get(h.id);
		// (the copy's loops are not versioned again)
		for (b in members)
			if (done.exists(b.id)) done.set(bmap.get(b.id).id, true);
		done.set(h2.id, true);
		// ---- the edges: before -> tests; slow -> the loop; the last test -> the copy
		retargetTerm(preB, h, first);
		preB.succs[preB.succs.indexOf(h)] = first;
		first.preds = [preB];
		var sj = add(slow, Jmp, Void);
		sj.targets = vector(h);
		slow.succs = [h];
		h.preds[pre] = slow;
		var gj = add(gb, Jmp, Void);
		gj.targets = vector(h2);
		gb.succs = [h2];
		h2.preds[pre] = gb;
		// ---- the edges out: the copy's too, with the copy's values in the phis there
		var seen = new Map<String, Bool>();
		for (e in exits) {
			var k = e.from.id + ">" + e.to.id;
			if (seen.exists(k)) continue;
			seen.set(k, true);
			var to = e.to, from2 = bmap.get(e.from.id);
			var n = to.preds.length;
			var preds = to.preds.copy();
			var add = [];
			for (q in 0...n)
				if (preds[q] == e.from) {
					preds.push(from2);
					add.push(q);
				}
			for (i in to.ins)
				if (!i.dead && i.op == Phi) {
					var args = new Vector<Int>(preds.length);
					Vector.blit(i.args, 0, args, 0, i.args.length);
					for (j in 0...add.length)
						args[n + j] = m(i.args[add[j]]);
					i.args = args;
				}
			to.preds = preds;
		}
		// ---- the values the loop makes that are used after it: read again
		// (SSA) where they are used, from the original or the copy, whichever
		// the code came from. A value used after the loop dominates the use,
		// so the blocks it leaves from are the ones it dominates
		var copies = new Map<Int, Bool>();
		for (nb in bmap)
			copies.set(nb.id, true);
		inline function local(b:MBlock):Bool
			return inLoop(b) || copies.exists(b.id);
		var escaping:Array<Int> = [];
		var esc = new Map<Int, Bool>();
		function note(id:Int) {
			if (id >= 0 && inLoop(v(id).block) && !esc.exists(id)) {
				esc.set(id, true);
				escaping.push(id);
			}
		}
		for (b in f.blocks) {
			if (local(b)) continue;
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.op == Phi) {
					for (q in 0...i.args.length)
						if (!local(b.preds[q])) note(i.args[q]);
					continue;
				}
				note(i.a);
				note(i.b);
				note(i.c);
				for (x in i.args)
					note(x);
			}
		}
		if (escaping.length == 0) return;
		var nb = 0;
		for (b in f.blocks)
			if (b.id >= nb) nb = b.id + 1;
		var made:Array<MIns> = [];
		for (x in escaping) {
			var d = v(x);
			var di = oldIndex.get(d.block.id);
			var ends = MFunc.ints(nb, SsaReader.NONE);
			for (b in members)
				if (cfg.dominates(di, oldIndex.get(b.id))) {
					ends[b.id] = x;
					ends[bmap.get(b.id).id] = m(x);
				}
			var rd = new SsaReader(f.entry, SsaReader.LAZY, ends, MFunc.ints(nb, SsaReader.NOTSET), b -> {
				var phi = new MIns(Phi, d.ty);
				phi.id = f.vals.length;
				f.vals.push(phi);
				phi.vty = d.vty;
				phi.block = b;
				made.push(phi);
				var k = 0;
				while (k < b.ins.length && b.ins[k].op == Phi)
					k++;
				b.ins.insert(k, phi);
				phi.id;
			}, (p, args) -> f.vals[p].args = args);
			rd.undefOf = () -> throw "hxmc: LoopVersion: " + f.name + ": v" + x + " read where it is not defined";
			for (b in f.blocks.copy()) {
				if (local(b)) continue;
				var entry = -1;
				for (i in b.ins) {
					if (i.dead) continue;
					if (i.op == Phi) {
						if (made.indexOf(i) >= 0) continue;
						for (q in 0...i.args.length)
							if (i.args[q] == x && !local(b.preds[q])) {
								var r = rd.readEnd(b.preds[q]);
								if (r != x) {
									var args = i.args.copy();
									args[q] = r;
									i.args = args;
								}
							}
						continue;
					}
					if (i.a == x || i.b == x || i.c == x || i.args.indexOf(x) >= 0) {
						if (entry < 0) entry = rd.readEntry(b);
						if (i.a == x) i.a = entry;
						if (i.b == x) i.b = entry;
						if (i.c == x) i.c = entry;
						if (i.args.indexOf(x) >= 0) i.args = i.args.map(a -> a == x ? entry : a);
					}
				}
			}
			rd.finish();
		}
		Ssa.trivialPhis(f.vals, made);
	}

	// a terminator's target from -> to
	static function retargetTerm(b:MBlock, from:MBlock, to:MBlock) {
		var t = b.term();
		if (t == null) throw "hxmc: LoopVersion: a block without a terminator";
		var ts = t.targets.copy();
		for (k in 0...ts.length)
			if (ts[k] == from) ts[k] = to;
		t.targets = ts;
	}
}
