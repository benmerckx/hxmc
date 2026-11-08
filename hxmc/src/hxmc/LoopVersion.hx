package hxmc;

import haxe.ds.Vector;
import hxmc.Mir;
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
class LoopVersion {
	// at most this many instructions in a loop copied
	static inline var MAX_SIZE = 400;
	// at most this many loops copied per function
	static inline var MAX_LOOPS = 8;
	// the largest step and look-ahead of a counter (counter + them stays below 2^31: an array is shorter)
	static inline var MAX_STEP = 16;

	// (Options.loopVersion, loopVersionWhy: set by Driver)
	public static var on = true;
	// (-D hxmc.loop-version=why: why each loop is left alone, by the number of its test in try1)
	public static var why = false;
	var curHead = -1;

	function no(k:Int):Bool {
		if (why) Sys.println('hxmc: LoopVersion: ${f.name} b${curHead}: no (${k})');
		return false;
	}

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
		if (why) Sys.println('hxmc: LoopVersion: ${f.name} loops: ' + [for (k in 0...order.length) if (bodies[k] != null) "b" + order[k].id + "(" + bodies[k].length + ")"].join(" "));
		var k = order.length;
		while (k-- > 1) { // inner loops first
			var h = order[k];
			var ks = bodies[k];
			if (ks == null || done.exists(h.id)) continue;
			done.set(h.id, true);
			var members = [for (x in ks) order[x]];
			if (try1(h, members)) {
				f.edited();
				versioned++;
				return true;
			}
		}
		return false;
	}

	function try1(h:MBlock, members:Array<MBlock>):Bool {
		curHead = h.id;
		var inL = new Map<Int, Bool>();
		for (b in members) {
			if (b.handler) return no(0);
			inL.set(b.id, true);
		}
		function inLoop(b:Null<MBlock>):Bool
			return b != null && inL.exists(b.id);
		inline function outside(id:Int):Bool
			return id >= 0 && !inLoop(v(id).block);
		// one way in, one way back
		if (h.preds.length != 2) return no(1);
		var pre = -1, latch = -1;
		for (k in 0...2)
			if (inLoop(h.preds[k])) latch = k else pre = k;
		if (pre < 0 || latch < 0) return no(2);
		// the exit: the header's branch, the only edge out
		var t = h.term();
		if (t == null || t.op != Br) return no(3);
		var exitK = -1;
		for (k in 0...2)
			if (!inLoop(t.targets[k])) {
				if (exitK >= 0) return no(4);
				exitK = k;
			}
		if (exitK < 0) return no(5);
		for (b in members)
			for (s in b.succs)
				if (!inLoop(s) && !(b == h && s == t.targets[exitK])) return no(6);
		var exitB = t.targets[exitK];
		if (exitB == t.targets[1 - exitK]) return no(7);
		// the test: counter < limit to stay (cmp lt), counter >= limit to leave (cmp ge)
		var c = v(t.a);
		if (c.op != Cmp || c.block != h) return no(8);
		var iv = -1, limit = -1;
		if (c.imm == (CLt : Int) && exitK == 1 || c.imm == (CGe : Int) && exitK == 0) {
			iv = c.a;
			limit = c.b;
		} else if (c.imm == (CGt : Int) && exitK == 1 || c.imm == (CLe : Int) && exitK == 0) {
			iv = c.b;
			limit = c.a;
		} else
			return no(9);
		// (the test may be of counter + c, c a small constant: the body then
		// runs while counter + c < limit, so counter + d is in range for d <= c)
		var ahead = 0;
		{
			var x = v(iv);
			if (x.op == Add && x.block == h && constOf(x.b) != null) {
				ahead = constOf(x.b);
				if (ahead < 0 || ahead > MAX_STEP) return no(17);
				iv = x.a;
			}
		}
		var phi = v(iv);
		if (phi.op != Phi || phi.block != h || phi.ty != I32 || phi.args.length != 2 || !outside(limit) || v(limit).ty != I32) return no(10);
		var start = phi.args[pre], next = v(phi.args[latch]);
		var step = next.op == Add && next.a == iv && inLoop(next.block) ? constOf(next.b) : null;
		if (step == null || step < 1 || step > MAX_STEP) return no(11);
		// what the loop does
		var size = 0;
		var gets:Array<MIns> = [];
		var fieldsWritten = new Map<Int, Bool>();
		for (b in members)
			for (i in b.ins) {
				if (i.dead) continue;
				size++;
				if (i.info != null && i.info.cold) return no(12);
				switch i.op {
					case Const | ConstF | SymAddr | Copy | Phi | Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Neg | Not | Div | Rem | UDiv | URem | Rotr | FAdd | FSub | FMul | FDiv | FNeg | FSqrt | FAbs | Cmp | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits | Select | Load | TlsLoad | Jmp | Br | Switch:
					case NullCheck | GetField | FieldAddr | EnumTag | TypeTest | ArrayLength | NArrayLength | NArrayGet | NArraySet:
					case SetField:
						fieldsWritten.set(fieldKey(i.info), true);
					case ArrayGet:
						gets.push(i);
					case Call if (i.sym != null && StringTools.startsWith(i.sym, MirBuild.SPECIAL) && !StringTools.startsWith(i.sym, MirBuild.SPECIAL + "atomic")):
					case _:
						return no(13);
				}
			}
		if (size > MAX_SIZE || gets.length == 0) return no(14);
		// the reads the copy takes: their arrays, and the indices they need
		var arrays:Array<{a:Int, obj:Int, field:Null<MIns>, kind:Int, upto:Bool, idx:Array<Int>}> = [];
		var taken:Array<MIns> = [];
		var anyPtr = false;
		for (g in gets) {
			var off = offsetOf(g.b, iv, ahead);
			var idxOk = off != null && g.block != h || outside(g.b);
			if (!idxOk) continue;
			var a = v(g.a);
			var obj = -1, field:Null<MIns> = null;
			if (!inLoop(a.block)) {} else if (a.op == GetField && outside(a.a) && !fieldsWritten.exists(fieldKey(a.info)) && a.info.t.match(TRef(_))) {
				obj = a.a;
				field = a;
			} else
				continue;
			var kind = MemLower.arrKind(g.info.t);
			var found = null;
			for (e in arrays)
				if (field == null ? e.field == null && e.a == g.a : e.field != null && e.obj == obj && fieldKey(e.field.info) == fieldKey(field.info)) found = e;
			if (found != null && found.kind != kind) continue;
			if (found == null) {
				found = {a: g.a, obj: obj, field: field, kind: kind, upto: false, idx: []};
				arrays.push(found);
			}
			if (off != null) found.upto = true else if (found.idx.indexOf(g.b) < 0) found.idx.push(g.b);
			taken.push(g);
			if (Opt.ptrElem(g.info.t)) anyPtr = true;
		}
		if (taken.length == 0) return no(15);
		// (a reference read left with its slow path writes everything: no gain then)
		for (g in gets)
			if (taken.indexOf(g) < 0 && Opt.ptrElem(g.info.t)) return no(16);
		version(h, members, inLoop, pre, latch, exitB, start, limit, arrays, taken);
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

	function isConst(id:Int, k:Int):Bool {
		var x = v(id);
		return x.op == Const && x.sym == null && x.imm == k;
	}

	function version(h:MBlock, members:Array<MBlock>, inLoop:Null<MBlock>->Bool, pre:Int, latch:Int, exitB:MBlock, start:Int, limit:Int,
			arrays:Array<{a:Int, obj:Int, field:Null<MIns>, kind:Int, upto:Bool, idx:Array<Int>}>, taken:Array<MIns>) {
		var preB = h.preds[pre];
		// ---- the test before the loop: blocks g0.. failing to slow, which enters the loop as it was
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
		function lzero():Int {
			var x = add(gb, Const, I64);
			return x.id;
		}
		// the start is not negative (the counter only grows from it)
		test(cmp(CGe, start, iconst(0)));
		var arrVal = new Map<Int, Int>(); // (arrays index -> the array before the loop)
		for (ai in 0...arrays.length) {
			var e = arrays[ai];
			var a = e.a;
			if (e.field != null) {
				test(cmp(CNe, e.obj, lzero()));
				var gf = add(gb, GetField, I64);
				gf.a = e.obj;
				gf.info = e.field.info.copy(null);
				gf.vty = e.field.vty;
				gf.pos = e.field.pos;
				a = gf.id;
			}
			arrVal.set(ai, a);
			test(cmp(CNe, a, lzero()));
			var kind = add(gb, Load, I32);
			kind.a = a;
			kind.imm = 4;
			kind.imm2 = 1;
			kind.size = 4;
			kind.mem = Opt.MHdr;
			test(cmp(CEq, kind.id, iconst(e.kind)));
			var len = add(gb, ArrayLength, I32);
			len.a = a;
			len.info = new OInfo();
			if (e.upto) test(cmp(CLe, limit, len.id));
			for (x in e.idx)
				test(cmp(CULt, x, len.id));
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
		// the exit: both loops leave to a new block, which merges what the
		// header made that is used after the loop
		var x = newBlock();
		retargetTerm(h, exitB, x);
		h.succs[h.succs.indexOf(exitB)] = x;
		retargetTerm(h2, exitB, x);
		h2.succs[h2.succs.indexOf(exitB)] = x;
		x.preds = [h, h2];
		var xj = new MIns(Jmp, Void);
		xj.targets = vector(exitB);
		var pi = exitB.preds.indexOf(h);
		exitB.preds[pi] = x;
		x.succs = [exitB];
		// values made in the loop used after it (the header's: the only exit is from it)
		var used = new Map<Int, Int>(); // value -> its merge
		var copies = new Map<Int, Bool>();
		for (nb in bmap)
			copies.set(nb.id, true);
		for (b in f.blocks) {
			if (inLoop(b) || copies.exists(b.id) || b == x) continue;
			for (i in b.ins) {
				if (i.dead) continue;
				inline function fix(id:Int):Int {
					if (id < 0 || !inLoop(v(id).block)) return id;
					var p = used.get(id);
					if (p == null) {
						var orig = v(id);
						var ph = new MIns(Phi, orig.ty);
						ph.id = f.vals.length;
						f.vals.push(ph);
						ph.vty = orig.vty;
						ph.block = x;
						ph.args = vector(id, m(id));
						x.ins.push(ph);
						used.set(id, p = ph.id);
					}
					return p;
				}
				i.a = fix(i.a);
				i.b = fix(i.b);
				i.c = fix(i.c);
				if (i.args.length > 0) i.args = i.args.map(a -> fix(a));
			}
		}
		xj.id = f.vals.length;
		f.vals.push(xj);
		xj.block = x;
		x.ins.push(xj);
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
