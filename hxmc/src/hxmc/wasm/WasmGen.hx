package hxmc.wasm;

import hxmc.Mir;
import hxmc.Obj;
import hxmc.Buf;
import hxmc.Lir.Bits;
import haxe.ds.Vector;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;
import hxmc.wasm.Enc;
import hxmc.MirBuild.Unsupported;

private enum Ctx {
	CIf;
	CLoop(b:Int);
	CBlock(b:Int);
	CPlain;
}

// One function's Mir (after hxmc's optimizations) to a WebAssembly function
// body (docs/hxmc.md, "WebAssembly"):
// - control flow: the structured form of Ramsey's "Beyond Relooper" (ICFP
//   2022) over the dominator tree: a node's merge children (two or more
//   forward predecessors) follow it in blocks it is nested in, a loop
//   header wraps its code in a loop, other children are inlined at their
//   one predecessor's branch (Haxe's control flow is reducible);
// - values: SSA values become locals, colored in dominator order so that
//   values not live at the same time share one (`coalesce`; in a try body,
//   what its handler reads stays live throughout); a value used
//   once in its own block is computed where it is used (on the value
//   stack) when that changes no order of side effects; constants and
//   frame addresses are recomputed at each use;
// - phis: the copies of an edge are done where its branch is written
//   (values pushed, then popped into the phis' locals: a parallel copy);
// - frame slots (StackAddr) live in linear memory below the stack-pointer
//   global, which the prologue moves and every return restores; the
//   prologue compares the new stack pointer with the stack's end
//   (rt_cstack_lo, a global) and calls rt_cstack_overflow below it: no guard
//   page, and what lies below the stack is the heap's other regions (the
//   runtime's stack, Gc.init) or the program's data (the linker's, until
//   _start switches);
// - try: the setjmp of MirBuild.tryStmt is 0 here, and the try body (the
//   dominator subtree of its first block) is wrapped in a try_table whose
//   catch-all lands on a pad: if the runtime's current handler (rt_hcur)
//   is this try's, the pad restores the stack pointer and branches to the
//   handler block (the second return of setjmp); else it throws on (the
//   exception belongs to an outer handler).
//   With -D hxmc.wasm-eh=legacy (engines without exnref) the try body is
//   a legacy `try` whose `catch_all` is the pad, and an exception that is
//   not this try's is thrown on with `rethrow`.
// - 32-bit values: pointers are I64 in Mir and wasm32 addresses are 32-bit;
//   an I64 value whose every use reads only its low 32 bits (addresses,
//   truncations, narrow stores, and additions, multiplications and bitwise
//   operations whose results are such values themselves) is computed as an
//   i32 (`narrowing`: a pointer loaded from memory with i32.load, offsets
//   added in i32) instead of being wrapped at each access.
// The body goes into the object's ".wasm" section under the function's
// symbol, prefixed with its signature; the indices of functions, types,
// globals and addresses are relocations LinkWasm resolves.
class WasmGen {
	public static inline var SECTION = ".wasm";
	public static inline var SP = "__stack_pointer";
	public static inline var HANDLER = "rt_hcur";
	// the lowest the stack pointer may go (LinkWasm: the linker's stack, then the runtime's)
	public static inline var STACK_LO = "rt_cstack_lo";
	public static inline var STACK_OVERFLOW = "rt_cstack_overflow";
	// the last exception a pad caught (an exnref global; LinkWasm)
	public static inline var EXNREF = "rt_exnref";
	public static var coalesceOn = Sys.getEnv("HXMC_WASM_COALESCE") != "0";

	var obj:Obj;
	var legacyEh:Bool; // legacy exception handling (try/catch_all/rethrow) instead of try_table and exnref
	var f:MFunc;
	var vals:Array<MIns>;
	var b:Buf; // the body
	var relocs:Array<{off:Int, kind:RelKind, sym:String, addend:Int}> = [];

	// the control-flow graph (reachable blocks)
	var nblk:Int;
	var rpo:Vector<MBlock> = vector();
	var rpoNum:Vector<Int>;
	var idom:Vector<Int>;
	var kids:Vector<Array<MBlock>>;
	var isLoop:Vector<Bool>;
	var isMerge:Vector<Bool>;
	var tryAddr:Vector<Int>; // block id of a try body's first block -> the handler's address value (-1)
	var tryHandler:Vector<MBlock>;
	var hasHandlers = false;

	// values
	var uses:Vector<Int>;
	var folded:Vector<Bool>;
	var narrow:Vector<Bool>; // I64 values computed as i32 (`narrowing`)
	var local:Vector<Int>;
	var localTys:Array<Int> = []; // the types of the locals after the parameters
	var nparams:Int;
	var fp = -1; // the frame pointer's local
	var frameSize = 0;
	var slotOff:Vector<Int> = vector();
	var scratch = new Map<Int, Int>(); // wasm type -> a scratch local (atomics)
	var ctx:Array<Ctx> = [];
	// the last local.set written (its opcode's offset, the body's length after
	// it, its local): a local.get of that local right after it makes it a local.tee
	var setAt = -1;
	var setEnd = -1;
	var setLocal = -1;
	var retAt = -1; // the body's length after the last return

	public function new(obj:Obj, legacyEh = false) {
		this.obj = obj;
		this.legacyEh = legacyEh;
	}

	public static function tyCode(t:MTy):Int
		return switch t {
			case I32: Enc.I32;
			case I64: Enc.I64;
			case F64: Enc.F64;
			case Void: Enc.VOID;
		};

	public static function tyChar(t:MTy):String
		return switch t {
			case I32: "i";
			case I64: "l";
			case F64: "d";
			case Void: "v";
		};

	// the signature string of a type ($t:<params>><result>)
	public static function sigOf(params:haxe.ds.Vector<MTy>, ret:MTy):String {
		var s = new StringBuf();
		for (p in params)
			s.add(tyChar(p));
		s.add(">");
		s.add(tyChar(ret));
		return s.toString();
	}

	// the signature of the import of a C function the program declares
	// (hxmc.ir.CInterop): wasm32's C ABI, pointers 32-bit, float f32,
	// structs by CAbi.wasmSig
	public static function importSig(sym:String):String {
		var sig = hxmc.CAbi.wasmSig(hxmc.ir.CInterop.SIGS.get(sym));
		function c(t:hxmc.ir.CInterop.CTy):String
			return switch t {
				case CI64: "l";
				case CF32: "f";
				case CF64: "d";
				case CVoid: "v";
				case _: "i";
			}
		return [for (a in sig.args) c(a)].join("") + ">" + c(sig.ret);
	}

	// ---- the function

	public function func(mf:MFunc) {
		f = mf;
		vals = f.vals;
		b = new Buf(1024);
		nparams = f.params.length;
		cfg();
		analyze();
		narrowing();
		frame();
		if (coalesceOn) coalesce() else plainLocals();
		// the prologue: the frame below the stack pointer
		if (fp >= 0) {
			global(Op.GlobalGet, SP);
			op(Op.I64Const);
			Enc.sleb(b, frameSize);
			op(Op.I64Sub);
			op(Op.LocalTee);
			Enc.uleb(b, fp);
			global(Op.GlobalGet, STACK_LO);
			op(Op.I64LtU);
			op(Op.If);
			b.u8(Enc.VOID);
			op(Op.Call);
			relocs.push({off: b.len, kind: RWasmFunc, sym: STACK_OVERFLOW, addend: 0});
			Enc.uleb5(b, 0);
			op(Op.End);
			op(Op.LocalGet);
			Enc.uleb(b, fp);
			global(Op.GlobalSet, SP);
		}
		doTree(f.entry);
		// (the end of a function ending in a return is not reached)
		if (f.ret != Void && retAt != b.len) op(Op.Unreachable);
		op(Op.End);
		// out: the signature, the locals, the body
		var sec = obj.section(SECTION, Text, 1);
		var out = sec.buf;
		var start = out.len;
		out.u8(f.params.length);
		for (p in f.params)
			out.u8(tyCode(p));
		out.u8(tyCode(f.ret));
		// locals: runs of one type
		var runs:Array<{n:Int, t:Int}> = [];
		for (t in localTys) {
			if (runs.length > 0 && runs[runs.length - 1].t == t) runs[runs.length - 1].n++;
			else runs.push({n: 1, t: t});
		}
		var lb = new Buf(16);
		Enc.uleb(lb, runs.length);
		for (r in runs) {
			Enc.uleb(lb, r.n);
			lb.u8(r.t);
		}
		var bodyStart = out.len + 5; // (after the body's size: a padded LEB)
		Enc.uleb5(out, lb.len + b.len);
		out.buf(lb);
		var base = out.len;
		out.buf(b);
		for (r in relocs)
			sec.relocs.push(new Reloc(base + r.off, r.kind, obj.sym(r.sym), r.addend));
		obj.define(f.name, sec, start, out.len - start, true);
		obj.sym(f.name).func = true;
	}

	// ---- analysis

	inline function op(o:Op)
		b.u8(o);

	function localSet(l:Int) {
		setAt = b.len;
		op(Op.LocalSet);
		Enc.uleb(b, l);
		setEnd = b.len;
		setLocal = l;
	}

	// (local.set x; local.get x is local.tee x: nothing can come between, as
	// any instruction, label or end writes bytes)
	function localGet(l:Int) {
		if (b.len == setEnd && l == setLocal) {
			b.set8(setAt, cast Op.LocalTee);
			setEnd = -1;
			return;
		}
		op(Op.LocalGet);
		Enc.uleb(b, l);
	}

	function cfg() {
		// (ids may exceed the number of blocks: passes drop blocks)
		nblk = 0;
		for (x in f.blocks)
			if (x.id >= nblk) nblk = x.id + 1;
		function grow(x:MBlock)
			if (x.id >= nblk) nblk = x.id + 1;
		for (x in f.blocks) {
			for (s in x.succs)
				grow(s);
			for (p in x.preds)
				grow(p);
		}
		var seen = new Vector<Bool>(nblk);
		var post:Array<MBlock> = [];
		var stack = [f.entry];
		var idx = [0];
		seen[f.entry.id] = true;
		while (stack.length > 0) {
			var top = stack.length - 1;
			var x = stack[top];
			if (idx[top] < x.succs.length) {
				var s = x.succs[idx[top]++];
				if (!seen[s.id]) {
					seen[s.id] = true;
					stack.push(s);
					idx.push(0);
				}
			} else {
				post.push(x);
				stack.pop();
				idx.pop();
			}
		}
		rpo = VectorTools.ofArrayReversed(post);
		rpoNum = MFunc.ints(nblk, -1);
		for (k in 0...rpo.length)
			rpoNum[rpo[k].id] = k;
		// dominators (Cooper, Harvey and Kennedy)
		idom = MFunc.ints(nblk, -1);
		idom[f.entry.id] = f.entry.id;
		var changed = true;
		while (changed) {
			changed = false;
			for (k in 1...rpo.length) {
				var x = rpo[k];
				var nd = -1;
				for (p in x.preds) {
					if (rpoNum[p.id] < 0 || idom[p.id] < 0) continue;
					nd = nd < 0 ? p.id : intersect(p.id, nd);
				}
				if (nd != idom[x.id]) {
					idom[x.id] = nd;
					changed = true;
				}
			}
		}
		kids = new Vector(nblk);
		for (k in 0...nblk)
			kids[k] = [];
		for (k in 1...rpo.length)
			kids[idom[rpo[k].id]].push(rpo[k]);
		isLoop = new Vector(nblk);
		isMerge = new Vector(nblk);
		for (x in rpo) {
			var fwd = new Map<Int, Bool>();
			for (p in x.preds) {
				if (rpoNum[p.id] < 0) continue;
				if (rpoNum[p.id] >= rpoNum[x.id]) {
					if (!dominates(x.id, p.id)) throw new Unsupported("wasm: an irreducible loop");
					isLoop[x.id] = true;
				} else
					fwd.set(p.id, true);
			}
			var n = 0;
			for (_ in fwd.keys())
				n++;
			if (n >= 2) isMerge[x.id] = true;
		}
		// try bodies: a branch to a handler block (MirBuild.tryStmt)
		tryAddr = MFunc.ints(nblk, -1);
		tryHandler = new Vector(nblk);
		for (x in rpo) {
			if (x.handler) {
				hasHandlers = true;
				isMerge[x.id] = true;
			}
			var t = x.term();
			if (t == null || t.op != Br) continue;
			var hi = t.targets[0].handler ? 0 : t.targets[1].handler ? 1 : -1;
			if (hi < 0) continue;
			var hb = t.targets[hi], tb = t.targets[1 - hi];
			var sj = setjmpOf(x);
			if (sj == null) throw new Unsupported("wasm: a handler block without its setjmp");
			// (a try body that is a merge node must come first: its pad branches to the handler's block)
			if (isMerge[tb.id] && rpoNum[tb.id] > rpoNum[hb.id]) throw new Unsupported("wasm: a try body after its handler");
			tryAddr[tb.id] = sj.args[0];
			tryHandler[tb.id] = hb;
		}
	}

	function setjmpOf(x:MBlock):Null<MIns> {
		for (i in x.ins)
			if (!i.dead && i.op == Call && i.returnsTwice) return i;
		return null;
	}

	function intersect(a:Int, c:Int):Int {
		while (a != c) {
			while (rpoNum[a] > rpoNum[c])
				a = idom[a];
			while (rpoNum[c] > rpoNum[a])
				c = idom[c];
		}
		return a;
	}

	function dominates(a:Int, x:Int):Bool {
		while (true) {
			if (x == a) return true;
			var d = idom[x];
			if (d == x || d < 0) return false;
			x = d;
		}
	}

	// the operands of i
	static inline function operands(i:MIns, fn:Int->Void) {
		switch i.op {
			case Param | Const | ConstF | SymAddr | TlsLoad | StackAddr | Jmp | Unreachable:
			case TlsStore | Copy | Neg | Not | FNeg | FSqrt | FAbs | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits | Br | Switch:
				fn(i.a);
			case Ret:
				if (i.a >= 0) fn(i.a);
			case Select:
				fn(i.a);
				fn(i.b);
				fn(i.c);
			case Load:
				fn(i.a);
				if (i.b >= 0) fn(i.b);
			case Store:
				fn(i.a);
				if (i.b >= 0) fn(i.b);
				fn(i.c);
			case Call:
				if (!i.returnsTwice) {
					if (i.sym == null) fn(i.a);
					for (x in i.args)
						fn(x);
				}
			case Phi:
				for (x in i.args)
					fn(x);
			case _:
				fn(i.a);
				fn(i.b);
		}
	}

	static inline function remat(i:MIns):Bool
		return i.op == Const || i.op == ConstF || i.op == SymAddr || i.op == StackAddr || (i.op == Call && i.returnsTwice);

	static inline function pure(i:MIns):Bool
		return switch i.op {
			case Load | TlsLoad | TlsStore | Store | Call | Phi | Param | Jmp | Br | Switch | Ret | Unreachable: false;
			case _: true;
		};

	static inline function isWrite(i:MIns):Bool
		return i.op == Store || i.op == TlsStore || (i.op == Call && !i.returnsTwice);

	// the instructions of x that are written in order (not phis, not dead)
	function body(x:MBlock):Array<MIns>
		return [for (i in x.ins) if (!i.dead && i.op != Phi) i];

	function analyze() {
		var n = vals.length;
		uses = MFunc.ints(n, 0);
		folded = new Vector(n);
		for (x in rpo)
			for (i in x.ins)
				if (!i.dead) operands(i, v -> uses[v]++);
		// a try's handler address is read by its pad
		for (k in 0...nblk)
			if (tryAddr[k] >= 0) uses[tryAddr[k]] += 2;
		var emitPos = MFunc.ints(n, -1);
		var user = MFunc.ints(n, -1);
		for (x in rpo) {
			var l = body(x);
			var at = new Map<Int, Int>();
			for (k in 0...l.length)
				at.set(l[k].id, k);
			// writes before position k
			var w = new Vector<Int>(l.length + 1);
			for (k in 0...l.length)
				w[k + 1] = w[k] + (isWrite(l[k]) ? 1 : 0);
			var k = l.length;
			while (k-- > 0) {
				var i = l[k];
				var ep = folded[i.id] ? emitPos[user[i.id]] : k;
				emitPos[i.id] = ep;
				if (i.op == Call && i.returnsTwice) continue;
				operands(i, v -> {
					var d = vals[v];
					if (uses[v] != 1 || d.block != x || remat(d) || folded[v]) return;
					var kv = at.get(v);
					if (kv == null || kv >= k) return;
					if (pure(d) || ((d.op == Load || d.op == TlsLoad) && w[ep] - w[kv + 1] == 0)) {
						folded[v] = true;
						user[v] = i.id;
					}
				});
			}
		}
	}

	// the type a value is computed in
	inline function ety(v:Int):MTy
		return narrow[v] ? I32 : vals[v].ty;

	// which I64 values only ever have their low 32 bits read (their uses'
	// demands, to a fixpoint: an arithmetic use passes its own on)
	function narrowing() {
		var n = vals.length;
		narrow = vals.mapToVector(i -> i.ty == I64 && !i.dead && narrowDef(i));
		var changed = true;
		while (changed) {
			changed = false;
			for (x in rpo)
				for (u in x.ins) {
					if (u.dead) continue;
					demands(u, (v, low) -> {
						if (!low && narrow[v]) {
							narrow[v] = false;
							changed = true;
						}
					});
				}
			// a try's handler address: compared in full by its pad
			for (k in 0...nblk)
				if (tryAddr[k] >= 0 && narrow[tryAddr[k]]) {
					narrow[tryAddr[k]] = false;
					changed = true;
				}
		}
	}

	// whether an I64 definition can be computed as an i32 (calls and
	// thread-locals wrap once where they are computed)
	static function narrowDef(i:MIns):Bool
		return switch i.op {
			case Load | Const | SymAddr | TlsLoad | Add | Sub | Mul | And | Or | Xor | Neg | Not | Copy | Phi | Select: true;
			case SExt | ZExt: true;
			case Shl: false; // (with a constant amount below 32: see demands)
			case Call: !i.returnsTwice;
			case _: false;
		};

	// each operand of u with whether u reads only its low 32 bits
	function demands(u:MIns, fn:(Int, Bool) -> Void) {
		var nu = narrow[u.id];
		switch u.op {
			case Load:
				fn(u.a, true);
				if (u.b >= 0) fn(u.b, true);
			case Store:
				fn(u.a, true);
				if (u.b >= 0) fn(u.b, true);
				fn(u.c, u.size <= 4);
			case Trunc:
				fn(u.a, true);
			case Add | Sub | Mul | And | Or | Xor:
				fn(u.a, nu);
				fn(u.b, nu);
			case Neg | Not | Copy:
				fn(u.a, nu);
			case Phi:
				for (v in u.args)
					fn(v, nu);
			case Select:
				fn(u.a, false);
				fn(u.b, nu);
				fn(u.c, nu);
			case Switch:
				fn(u.a, true);
			case Ret:
				if (u.a >= 0) fn(u.a, f.ret == I32);
			case Call:
				if (!u.returnsTwice) {
					if (u.sym == null) fn(u.a, true);
					var tys = u.argTys;
					for (k in 0...u.args.length)
						fn(u.args[k], tys[k] == I32);
				}
			case _:
				operands(u, v -> fn(v, false));
		}
	}

	function frame() {
		if (f.slots.length == 0) return;
		var off = 0;
		slotOff = new Vector(f.slots.length);
		for (k in 0...f.slots.length) {
			var s = f.slots[k];
			var al = s.align < 8 ? 8 : s.align;
			off = (off + al - 1) & ~(al - 1);
			slotOff[k] = off;
			off += s.size;
		}
		frameSize = (off + 15) & ~15;
		fp = newLocal(Enc.I64);
	}

	function newLocal(t:Int):Int {
		localTys.push(t);
		return nparams + localTys.length - 1;
	}

	function needsLocal(i:MIns):Bool
		return !i.dead && i.ty != Void && i.op != Param && !remat(i) && !folded[i.id] && uses[i.id] > 0;

	function plainLocals() {
		local = MFunc.ints(vals.length, -1);
		for (x in rpo)
			for (i in x.ins)
				if (needsLocal(i)) local[i.id] = newLocal(tyCode(ety(i.id)));
	}

	// a set of n bits per block
	static function sets(nblk:Int, n:Int):Vector<Bits> {
		var v = new Vector<Bits>(nblk);
		for (k in 0...nblk)
			v[k] = new Bits(n);
		return v;
	}

	// SSA coloring: in dominator-tree preorder, a value takes a local of its
	// type that no value live at its definition holds; a local is free again
	// after its value's last use
	function coalesce() {
		local = MFunc.ints(vals.length, -1);
		var want = vals.mapToVector(needsLocal);
		// the values that get locals, numbered densely for the bit sets
		var wid = MFunc.ints(vals.length, -1), ids = [];
		for (v in 0...vals.length)
			if (want[v]) {
				wid[v] = ids.length;
				ids.push(v);
			}
		var n = ids.length;
		// liveness of the values that get locals (phi operands: live out of the predecessor)
		var liveIn = sets(nblk, n);
		var liveOut = sets(nblk, n);
		var gen = sets(nblk, n);
		var kill = sets(nblk, n);
		var phiUse = sets(nblk, n); // phi operands for the edges out of a block
		for (x in rpo) {
			var g = gen[x.id], kl = kill[x.id];
			for (i in x.ins) {
				if (i.dead) continue;
				if (i.op == Phi) {
					if (want[i.id]) kl.set(wid[i.id]);
					for (pi in 0...x.preds.length) {
						var p = x.preds[pi];
						if (rpoNum[p.id] < 0) continue;
						var v = i.args[pi];
						if (want[v]) phiUse[p.id].set(wid[v]);
					}
					continue;
				}
				useTree(i, v -> if (want[v] && !kl.get(wid[v])) g.set(wid[v]));
				if (want[i.id]) kl.set(wid[i.id]);
			}
		}
		var changed = true;
		while (changed) {
			changed = false;
			var k = rpo.length;
			while (k-- > 0) {
				var x = rpo[k];
				var out = liveOut[x.id];
				for (s in x.succs)
					if (rpoNum[s.id] >= 0 && out.union(liveIn[s.id])) changed = true;
				if (out.union(phiUse[x.id])) changed = true;
				var inn = liveIn[x.id];
				for (wi in 0...inn.w.length) {
					var v = gen[x.id].w[wi] | (out.w[wi] & ~kill[x.id].w[wi]);
					if (v != inn.w[wi]) {
						inn.w[wi] = v;
						changed = true;
					}
				}
			}
		}
		gen = kill = phiUse = null;
		// a try body may branch to its handler (through its pad) anywhere: what
		// the handler block reads (its live-in values, its phis' operands from
		// the setjmp's block, the handler's address) is live in all of the body
		// (the dominator subtree of its first block)
		if (hasHandlers)
			for (x in rpo) {
				if (tryAddr[x.id] < 0) continue;
				var hb = tryHandler[x.id];
				var h = new Bits(n);
				h.union(liveIn[hb.id]);
				for (i in hb.ins)
					if (!i.dead && i.op == Phi && want[i.args[0]]) h.set(wid[i.args[0]]);
				if (want[tryAddr[x.id]]) h.set(wid[tryAddr[x.id]]);
				var stack = [x];
				while (stack.length > 0) {
					var y = stack.pop();
					liveIn[y.id].union(h);
					liveOut[y.id].union(h);
					for (c in kids[y.id])
						stack.push(c);
				}
			}
		// colors: per wasm type, the locals of that type and whether each is taken
		var pools = new Map<Int, Array<Int>>();
		var taken = new Map<Int, Bool>();
		function take(t:Int):Int {
			var p = pools.get(t);
			if (p == null) pools.set(t, p = []);
			for (l in p)
				if (!taken.exists(l)) {
					taken.set(l, true);
					return l;
				}
			var l = newLocal(t);
			p.push(l);
			taken.set(l, true);
			return l;
		}
		function walk(x:MBlock) {
			var saved = [for (l in taken.keys()) l];
			taken = new Map();
			// live in: their locals are taken
			var inn = liveIn[x.id];
			for (wi in 0...inn.w.length) {
				var m = inn.w[wi];
				while (m != 0) {
					var bit = m & -m;
					var v = ids[(wi << 5) + bitIndex(bit)];
					m &= m - 1;
					if (local[v] >= 0) taken.set(local[v], true);
				}
			}
			// the last use of each value in the block (by statement index)
			var l = [for (i in x.ins) if (!i.dead) i];
			var last = new Map<Int, Int>();
			for (k in 0...l.length)
				if (l[k].op != Phi && !folded[l[k].id] && !remat(l[k])) useTree(l[k], v -> if (want[v]) last.set(v, k));
			var out = liveOut[x.id];
			for (k in 0...l.length) {
				var i = l[k];
				if (i.op != Phi && (folded[i.id] || remat(i))) continue;
				if (i.op != Phi)
					useTree(i, v -> if (want[v] && last.get(v) == k && !out.get(wid[v]) && local[v] >= 0) taken.remove(local[v]));
				if (want[i.id]) {
					local[i.id] = take(tyCode(ety(i.id)));
					// a value never used afterwards frees its local at once
					if (!out.get(wid[i.id]) && !last.exists(i.id) && i.op != Phi) taken.remove(local[i.id]);
				}
			}
			for (c in kids[x.id])
				walk(c);
			taken = new Map();
			for (s in saved)
				taken.set(s, true);
		}
		walk(f.entry);
	}

	static inline function bitIndex(b:Int):Int {
		var i = 0;
		while (b != 1 && b != 0) {
			b >>>= 1;
			i++;
		}
		return i;
	}

	// the operands an instruction reads where it is written: its own and
	// those of the operands computed in place
	function useTree(i:MIns, fn:Int->Void) {
		if (i.op == Call && i.returnsTwice) return;
		operands(i, v -> {
			if (folded[v]) useTree(vals[v], fn) else fn(v);
		});
	}

	// ---- structure

	function depth(c:Ctx):Int {
		var k = ctx.length;
		while (k-- > 0)
			if (Type.enumEq(ctx[k], c)) return ctx.length - 1 - k;
		throw new Unsupported("wasm: no label for a branch");
	}

	function br(c:Ctx) {
		op(Op.Br);
		Enc.uleb(b, depth(c));
	}

	function doTree(x:MBlock) {
		var tryHere = tryAddr[x.id] >= 0;
		if (tryHere && legacyEh) {
			op(Op.Try);
			b.u8(Enc.VOID);
			ctx.push(CPlain);
		} else if (tryHere) {
			op(Op.Block);
			b.u8(Enc.EXNREF);
			ctx.push(CPlain);
			op(Op.TryTable);
			b.u8(Enc.VOID);
			b.u8(1); // one catch clause
			b.u8(3); // catch_all_ref
			b.u8(0); // to the block around it, with the exception
			ctx.push(CPlain);
		}
		var ys = [for (c in kids[x.id]) if (isMerge[c.id]) c];
		ys.sort((p, q) -> rpoNum[q.id] - rpoNum[p.id]);
		if (isLoop[x.id]) {
			op(Op.Loop);
			b.u8(Enc.VOID);
			ctx.push(CLoop(x.id));
			nodeWithin(x, ys, 0);
			ctx.pop();
			op(Op.End);
			op(Op.Unreachable);
		} else
			nodeWithin(x, ys, 0);
		if (tryHere && legacyEh) {
			// the pad is the catch_all (in the try's label, which rethrow
			// names); the body never falls through to it (as with try_table)
			op(Op.CatchAll);
			if (fp >= 0) {
				op(Op.LocalGet);
				Enc.uleb(b, fp);
				global(Op.GlobalSet, SP);
			}
			global(Op.GlobalGet, HANDLER);
			value(tryAddr[x.id]);
			op(Op.I64Ne);
			op(Op.If);
			b.u8(Enc.VOID);
			op(Op.Rethrow);
			b.u8(1); // the try, around the if
			op(Op.End);
			var hb = tryHandler[x.id];
			var from = hb.preds[0];
			moves(from, hb);
			br(CBlock(hb.id));
			op(Op.End);
			ctx.pop();
			op(Op.Unreachable);
		} else if (tryHere) {
			op(Op.End);
			ctx.pop();
			op(Op.Unreachable);
			op(Op.End);
			ctx.pop();
			// the pad: the exception is kept (rt_throw and the pads throw it
			// again with throw_ref: no new exception object per throw); this
			// try's exception, else an outer one's
			global(Op.GlobalSet, EXNREF);
			if (fp >= 0) {
				op(Op.LocalGet);
				Enc.uleb(b, fp);
				global(Op.GlobalSet, SP);
			}
			global(Op.GlobalGet, HANDLER);
			value(tryAddr[x.id]);
			op(Op.I64Ne);
			op(Op.If);
			b.u8(Enc.VOID);
			global(Op.GlobalGet, EXNREF);
			op(Op.ThrowRef);
			op(Op.End);
			var hb = tryHandler[x.id];
			var from = hb.preds[0];
			moves(from, hb);
			br(CBlock(hb.id));
		}
	}

	function nodeWithin(x:MBlock, ys:Array<MBlock>, k:Int) {
		if (k == ys.length) {
			block(x);
			return;
		}
		op(Op.Block);
		b.u8(Enc.VOID);
		ctx.push(CBlock(ys[k].id));
		nodeWithin(x, ys, k + 1);
		ctx.pop();
		op(Op.End);
		doTree(ys[k]);
	}

	function isLabel(src:MBlock, dst:MBlock):Bool
		return rpoNum[dst.id] <= rpoNum[src.id] || isMerge[dst.id];

	function labelOf(src:MBlock, dst:MBlock):Ctx
		return rpoNum[dst.id] <= rpoNum[src.id] ? CLoop(dst.id) : CBlock(dst.id);

	function doBranch(src:MBlock, dst:MBlock) {
		moves(src, dst);
		if (isLabel(src, dst)) br(labelOf(src, dst)) else doTree(dst);
	}

	// the phis of dst that get values on the edge from src
	function edgePhis(src:MBlock, dst:MBlock):Array<{phi:MIns, v:Int}> {
		var pi = dst.preds.indexOf(src);
		var out = [];
		for (i in dst.ins) {
			if (i.op != Phi) {
				if (!i.dead) break;
				continue;
			}
			if (i.dead || local[i.id] < 0) continue;
			var v = i.args[pi];
			if (local[v] == local[i.id] && local[v] >= 0) continue;
			out.push({phi: i, v: v});
		}
		return out;
	}

	function moves(src:MBlock, dst:MBlock) {
		var ps = edgePhis(src, dst);
		for (p in ps)
			valueAs(p.v, ety(p.phi.id));
		var k = ps.length;
		while (k-- > 0)
			localSet(local[ps[k].phi.id]);
	}

	// the block's instructions and its terminator
	function block(x:MBlock) {
		for (i in x.ins) {
			if (i.dead || i.op == Phi) continue;
			if (i.isTerm()) {
				term(x, i);
				return;
			}
			// (a parameter: read from its local where it is used, value)
			if (folded[i.id] || remat(i) || i.op == Param) continue;
			if (i.ty != Void && uses[i.id] == 0 && (pure(i) || i.op == Load || i.op == TlsLoad)) continue;
			ins(i);
			if (i.ty != Void) {
				if (local[i.id] >= 0)
					localSet(local[i.id]);
				else
					op(Op.Drop);
			}
		}
		throw new Unsupported("wasm: a block without a terminator");
	}

	function term(x:MBlock, t:MIns) {
		switch t.op {
			case Jmp:
				doBranch(x, t.targets[0]);
			case Unreachable:
				op(Op.Unreachable);
			case Ret:
				if (t.a >= 0) valueAs(t.a, f.ret);
				if (fp >= 0) {
					op(Op.LocalGet);
					Enc.uleb(b, fp);
					op(Op.I64Const);
					Enc.sleb(b, frameSize);
					op(Op.I64Add);
					global(Op.GlobalSet, SP);
				}
				op(Op.Return);
				retAt = b.len;
			case Br:
				var tt = t.targets[0], ff = t.targets[1];
				if (tt.handler || ff.handler) {
					// (setjmp returned 0: the try body)
					doBranch(x, tt.handler ? ff : tt);
					return;
				}
				if (tt == ff) {
					doBranch(x, tt);
					return;
				}
				cond(t.a);
				if (edgePhis(x, tt).length == 0 && isLabel(x, tt)) {
					op(Op.BrIf);
					Enc.uleb(b, depth(labelOf(x, tt)));
					doBranch(x, ff);
				} else if (edgePhis(x, ff).length == 0 && isLabel(x, ff)) {
					op(Op.I32Eqz);
					op(Op.BrIf);
					Enc.uleb(b, depth(labelOf(x, ff)));
					doBranch(x, tt);
				} else {
					op(Op.If);
					b.u8(Enc.VOID);
					ctx.push(CIf);
					doBranch(x, tt);
					ctx.pop();
					op(Op.End);
					doBranch(x, ff);
				}
			case Switch:
				switchTerm(x, t);
			case _:
				throw new Unsupported("wasm: terminator " + MFunc.opName(t.op));
		}
	}

	function switchTerm(x:MBlock, t:MIns) {
		var def = t.targets[t.targets.length - 1];
		var dist:Array<MBlock> = [];
		for (d in t.targets)
			if (dist.indexOf(d) < 0) dist.push(d);
		var cases = t.cases;
		if (cases.length == 0) {
			doBranch(x, def);
			return;
		}
		var lo = cases[0], hi = cases[0];
		for (c in cases) {
			if (c < lo) lo = c;
			if (c > hi) hi = c;
		}
		var span = hi - lo + 1;
		var dense = span > 0 && span <= 4 * cases.length + 16 && span < 65536;
		// blocks: the last distinct target outermost
		var k = dist.length;
		while (k-- > 0) {
			op(Op.Block);
			b.u8(Enc.VOID);
			ctx.push(CPlain);
		}
		var labelIdx = (d:MBlock) -> dist.indexOf(d);
		if (dense) {
			valueAs(t.a, I32);
			if (lo != 0) {
				op(Op.I32Const);
				Enc.sleb(b, lo);
				op(Op.I32Sub);
			}
			var table = new Vector<Int>(span, labelIdx(def));
			for (ci in 0...cases.length)
				table[cases[ci] - lo] = labelIdx(t.targets[ci]);
			op(Op.BrTable);
			Enc.uleb(b, span);
			for (e in table)
				Enc.uleb(b, e);
			Enc.uleb(b, labelIdx(def));
		} else {
			// comparisons (the value in a scratch local)
			var s = scratchLocal(Enc.I32);
			valueAs(t.a, I32);
			localSet(s);
			for (ci in 0...cases.length) {
				localGet(s);
				op(Op.I32Const);
				Enc.sleb(b, cases[ci]);
				op(Op.I32Eq);
				op(Op.BrIf);
				Enc.uleb(b, labelIdx(t.targets[ci]));
			}
			op(Op.Br);
			Enc.uleb(b, labelIdx(def));
		}
		for (d in dist) {
			ctx.pop();
			op(Op.End);
			doBranch(x, d);
		}
	}

	// a scratch local of type t & 255 (keys above 255: a second one)
	function scratchLocal(t:Int):Int {
		var l = scratch.get(t);
		if (l == null) {
			l = newLocal(t & 255);
			scratch.set(t, l);
		}
		return l;
	}

	// ---- values

	function global(o:Op, sym:String) {
		op(o);
		relocs.push({off: b.len, kind: RWasmGlobal, sym: sym, addend: 0});
		Enc.uleb5(b, 0);
	}

	function value(v:Int) {
		var i = vals[v];
		if (i.op == Param) {
			op(Op.LocalGet);
			Enc.uleb(b, i.imm);
			return;
		}
		if (local[v] >= 0) {
			localGet(local[v]);
			return;
		}
		if (!folded[v] && !remat(i)) throw new Unsupported("wasm: value v" + v + " (" + MFunc.opName(i.op) + ") has no local");
		ins(i);
	}

	// v != 0 as an i32
	function cond(v:Int) {
		value(v);
		if (ety(v) == I64) {
			op(Op.I64Eqz);
			op(Op.I32Eqz);
		}
	}

	// v converted to t
	function valueAs(v:Int, t:MTy) {
		var i = vals[v];
		// (a constant or address recomputed at a use that reads 32 bits: an i32 there)
		if (t == I32 && i.ty == I64 && !narrow[v] && (i.op == Const || i.op == SymAddr)) {
			narrow[v] = true;
			ins(i);
			narrow[v] = false;
			return;
		}
		value(v);
		if (narrow[v] && t == I64) throw new Unsupported("wasm: a 32-bit value v" + v + " read as I64");
		conv(ety(v), t);
	}

	function conv(from:MTy, to:MTy) {
		if (from == to || to == Void) return;
		if (from == I32 && to == I64) op(Op.I64ExtendI32S);
		else if (from == I64 && to == I32) op(Op.I32WrapI64);
		else throw new Unsupported("wasm: converting " + MFunc.tyName(from) + " to " + MFunc.tyName(to));
	}

	// a 32-bit address on the stack; returns the memarg offset
	function addr(base:Int, index:Int, scale:Int, disp:Int):Int {
		valueAs(base, I32);
		if (index >= 0) {
			valueAs(index, I32);
			if (scale != 1) {
				var sh = scale == 2 ? 1 : scale == 4 ? 2 : scale == 8 ? 3 : -1;
				op(Op.I32Const);
				Enc.sleb(b, sh >= 0 ? sh : scale);
				op(sh >= 0 ? Op.I32Shl : Op.I32Mul);
			}
			op(Op.I32Add);
		}
		if (disp < 0) {
			op(Op.I32Const);
			Enc.sleb(b, disp);
			op(Op.I32Add);
			return 0;
		}
		return disp;
	}

	function memarg(align:Int, off:Int) {
		Enc.uleb(b, align);
		Enc.uleb(b, off);
	}

	static function log2(n:Int):Int
		return n == 8 ? 3 : n == 4 ? 2 : n == 2 ? 1 : 0;

	function i64const(lo:Int, hi:Int) {
		op(Op.I64Const);
		Enc.sleb64(b, lo, hi);
	}

	function ins(i:MIns) {
		var t = ety(i.id);
		switch i.op {
			case Param:
				op(Op.LocalGet);
				Enc.uleb(b, i.imm);
			case Const if (i.sym != null):
				// a link-time number (Prep's absolute symbols) + imm
				op(t == I64 ? Op.I64Const : Op.I32Const);
				relocs.push({off: b.len, kind: t == I64 ? RWasmAddr : RWasmAddr32, sym: i.sym, addend: i.imm});
				for (_ in 0...(t == I64 ? 9 : 4))
					b.u8(0x80);
				b.u8(0);
			case Const:
				if (t == I64) i64const(i.imm, i.imm2) else {
					op(Op.I32Const);
					Enc.sleb(b, i.imm);
				}
			case ConstF:
				op(Op.F64Const);
				var bits = haxe.io.FPHelper.doubleToI64(i.f);
				b.u32(bits.low);
				b.u32(bits.high);
			case SymAddr if (t == I32):
				op(Op.I32Const);
				relocs.push({off: b.len, kind: RWasmAddr32, sym: i.sym, addend: i.imm});
				for (_ in 0...4)
					b.u8(0x80);
				b.u8(0);
			case SymAddr:
				op(Op.I64Const);
				relocs.push({off: b.len, kind: RWasmAddr, sym: i.sym, addend: i.imm});
				for (_ in 0...9)
					b.u8(0x80);
				b.u8(0);
				conv(I64, t);
			case TlsLoad:
				global(Op.GlobalGet, i.sym);
				conv(I64, t);
			case TlsStore:
				valueAs(i.a, I64);
				global(Op.GlobalSet, i.sym);
			case StackAddr:
				op(Op.LocalGet);
				Enc.uleb(b, fp);
				var off = slotOff[i.imm];
				if (off != 0) {
					op(Op.I64Const);
					Enc.sleb(b, off);
					op(Op.I64Add);
				}
			case Copy:
				valueAs(i.a, t);
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Div | Rem | Rotr:
				valueAs(i.a, t);
				valueAs(i.b, t);
				var w = t == I64;
				op(switch i.op {
					case Add: w ? Op.I64Add : Op.I32Add;
					case Sub: w ? Op.I64Sub : Op.I32Sub;
					case Mul: w ? Op.I64Mul : Op.I32Mul;
					case And: w ? Op.I64And : Op.I32And;
					case Or: w ? Op.I64Or : Op.I32Or;
					case Xor: w ? Op.I64Xor : Op.I32Xor;
					case Shl: w ? Op.I64Shl : Op.I32Shl;
					case Sar: w ? Op.I64ShrS : Op.I32ShrS;
					case Shr: w ? Op.I64ShrU : Op.I32ShrU;
					case Div: w ? Op.I64DivS : Op.I32DivS;
					case Rem: w ? Op.I64RemS : Op.I32RemS;
					case _: w ? Op.I64Rotr : Op.I32Rotr;
				});
			case Neg:
				if (t == I64) i64const(0, 0) else {
					op(Op.I32Const);
					b.u8(0);
				}
				valueAs(i.a, t);
				op(t == I64 ? Op.I64Sub : Op.I32Sub);
			case Not:
				valueAs(i.a, t);
				if (t == I64) i64const(-1, -1) else {
					op(Op.I32Const);
					Enc.sleb(b, -1);
				}
				op(t == I64 ? Op.I64Xor : Op.I32Xor);
			case FAdd | FSub | FMul | FDiv:
				value(i.a);
				value(i.b);
				op(i.op == FAdd ? Op.F64Add : i.op == FSub ? Op.F64Sub : i.op == FMul ? Op.F64Mul : Op.F64Div);
			case FNeg | FSqrt | FAbs:
				value(i.a);
				op(i.op == FNeg ? Op.F64Neg : i.op == FSqrt ? Op.F64Sqrt : Op.F64Abs);
			case Cmp:
				var ta = vals[i.a].ty, tb = vals[i.b].ty;
				var ct = ta == F64 ? F64 : (ta == I64 || tb == I64) ? I64 : I32;
				valueAs(i.a, ct);
				valueAs(i.b, ct);
				op(cmpOp(i.imm, ct));
			case SExt | ZExt if (t == I32):
				valueAs(i.a, I32);
			case SExt:
				value(i.a);
				if (ety(i.a) == I32) op(Op.I64ExtendI32S);
			case ZExt:
				value(i.a);
				if (ety(i.a) == I32) op(Op.I64ExtendI32U);
			case Trunc:
				valueAs(i.a, I32);
			case I2F:
				value(i.a);
				op(vals[i.a].ty == I64 ? Op.F64ConvertI64S : Op.F64ConvertI32S);
			case F2I:
				value(i.a);
				op(Op.Prefix);
				Enc.uleb(b, t == I64 ? 6 : 2);
			case BitsToF:
				valueAs(i.a, I64);
				op(Op.F64ReinterpretI64);
			case FToBits:
				value(i.a);
				op(Op.I64ReinterpretF64);
			case Select:
				valueAs(i.b, t);
				valueAs(i.c, t);
				cond(i.a);
				op(Op.Select);
			case Load:
				var off = addr(i.a, i.b, i.imm2, i.imm);
				var sz = i.size;
				op(switch t {
					case F64: Op.F64Load;
					case I64: sz == 8 ? Op.I64Load : sz == 4 ? (i.signed ? Op.I64Load32S : Op.I64Load32U) : sz == 2 ? (i.signed ? Op.I64Load16S : Op.I64Load16U) : (i.signed ? Op.I64Load8S : Op.I64Load8U);
					case _: sz == 4 || sz == 8 ? Op.I32Load : sz == 2 ? (i.signed ? Op.I32Load16S : Op.I32Load16U) : (i.signed ? Op.I32Load8S : Op.I32Load8U);
				});
				memarg(log2(t == I32 && sz == 8 ? 4 : sz), off);
			case Store:
				var off = addr(i.a, i.b, i.imm2, i.imm);
				var vt = vals[i.c].ty;
				var sz = i.size;
				if (vt == F64) {
					value(i.c);
					op(Op.F64Store);
				} else if (sz == 8) {
					valueAs(i.c, I64);
					op(Op.I64Store);
				} else if (vt == I64 && !narrow[i.c]) {
					value(i.c);
					op(sz == 4 ? Op.I64Store32 : sz == 2 ? Op.I64Store16 : Op.I64Store8);
				} else {
					value(i.c);
					op(sz == 4 ? Op.I32Store : sz == 2 ? Op.I32Store16 : Op.I32Store8);
				}
				memarg(log2(sz), off);
			case Call:
				call(i);
				if (t == I32 && i.ty == I64) op(Op.I32WrapI64);
			case _:
				throw new Unsupported("wasm: " + MFunc.opName(i.op));
		}
	}

	static function cmpOp(c:Int, t:MTy):Op {
		var cond:Cond = c;
		if (t == F64)
			return switch cond {
				case FEq | CEq: Op.F64Eq;
				case FNe | CNe: Op.F64Ne;
				case FLt | CLt: Op.F64Lt;
				case FLe | CLe: Op.F64Le;
				case FGt | CGt: Op.F64Gt;
				case _: Op.F64Ge;
			};
		var w = t == I64;
		return switch cond {
			case CEq: w ? Op.I64Eq : Op.I32Eq;
			case CNe: w ? Op.I64Ne : Op.I32Ne;
			case CLt: w ? Op.I64LtS : Op.I32LtS;
			case CLe: w ? Op.I64LeS : Op.I32LeS;
			case CGt: w ? Op.I64GtS : Op.I32GtS;
			case CGe: w ? Op.I64GeS : Op.I32GeS;
			case CULt: w ? Op.I64LtU : Op.I32LtU;
			case CULe: w ? Op.I64LeU : Op.I32LeU;
			case CUGt: w ? Op.I64GtU : Op.I32GtU;
			case CUGe: w ? Op.I64GeU : Op.I32GeU;
			case _: throw new Unsupported("wasm: a float condition on integers");
		};
	}

	function call(i:MIns) {
		if (i.returnsTwice) {
			// setjmp: the first return (the second is the pad's branch)
			op(Op.I32Const);
			b.u8(0);
			return;
		}
		if (i.sym != null && StringTools.startsWith(i.sym, MirBuild.SPECIAL)) {
			special(i, i.sym.substr(MirBuild.SPECIAL.length));
			return;
		}
		// (a C call, MirBuild.cCall; a program's extern the runtime implements
		// in Haxe, as __errno_location, is a call of that function: Lower.bindHosts)
		var imp = i.sym != null && i.cCall ? hxmc.ir.CInterop.SIGS.get(i.sym) : null;
		if (imp != null && hxmc.ir.CInterop.USER.exists(i.sym)) {
			imp = hxmc.CAbi.wasmSig(imp);
			// an import (LinkWasm): pointers as i32, floats as f32
			var tys = i.argTys;
			for (k in 0...i.args.length)
				switch imp.args[k] {
					case CPtr:
						valueAs(i.args[k], I64);
						op(Op.I32WrapI64);
					case CF32:
						valueAs(i.args[k], F64);
						op(Op.F32DemoteF64);
					case _: valueAs(i.args[k], tys[k]);
				}
			op(Op.Call);
			relocs.push({off: b.len, kind: RWasmFunc, sym: i.sym, addend: 0});
			Enc.uleb5(b, 0);
			switch imp.ret {
				case CPtr: op(Op.I64ExtendI32U);
				case CF32: op(Op.F64PromoteF32);
				case _:
			}
			return;
		}
		var tys = i.argTys;
		for (k in 0...i.args.length)
			valueAs(i.args[k], tys[k]);
		if (i.sym != null) {
			op(Op.Call);
			relocs.push({off: b.len, kind: RWasmFunc, sym: i.sym, addend: 0});
			Enc.uleb5(b, 0);
		} else {
			valueAs(i.a, I32);
			op(Op.CallIndirect);
			relocs.push({off: b.len, kind: RWasmType, sym: "$t:" + sigOf(tys, i.ty), addend: 0});
			Enc.uleb5(b, 0);
			b.u8(0); // table 0
		}
	}

	// MirBuild.special: atomics as plain accesses (one thread), float32 conversions
	function special(i:MIns, name:String) {
		inline function at() {
			valueAs(i.args[0], I32);
		}
		switch name {
			case "atomic_load4":
				at();
				op(Op.I32Load);
				memarg(2, 0);
			case "atomic_load8":
				at();
				op(Op.I64Load);
				memarg(3, 0);
			case "atomic_store4":
				at();
				valueAs(i.args[1], I32);
				op(Op.I32Store);
				memarg(2, 0);
			case "atomic_store8":
				at();
				valueAs(i.args[1], I64);
				op(Op.I64Store);
				memarg(3, 0);
			case "atomic_add4" | "atomic_add8" | "atomic_xchg4" | "atomic_xchg8" | "atomic_cas4" | "atomic_cas8":
				var w = StringTools.endsWith(name, "8");
				var ty = w ? I64 : I32;
				var a = scratchLocal(Enc.I32);
				var old = scratchLocal(256 + (w ? Enc.I64 : Enc.I32)); // (not the address's)
				at();
				op(Op.LocalSet);
				Enc.uleb(b, a);
				op(Op.LocalGet);
				Enc.uleb(b, a);
				op(w ? Op.I64Load : Op.I32Load);
				memarg(w ? 3 : 2, 0);
				op(Op.LocalSet);
				Enc.uleb(b, old);
				if (StringTools.startsWith(name, "atomic_cas")) {
					op(Op.LocalGet);
					Enc.uleb(b, old);
					valueAs(i.args[1], ty);
					op(w ? Op.I64Eq : Op.I32Eq);
					op(Op.If);
					b.u8(Enc.VOID);
					op(Op.LocalGet);
					Enc.uleb(b, a);
					valueAs(i.args[2], ty);
					op(w ? Op.I64Store : Op.I32Store);
					memarg(w ? 3 : 2, 0);
					op(Op.End);
				} else {
					op(Op.LocalGet);
					Enc.uleb(b, a);
					if (StringTools.startsWith(name, "atomic_add")) {
						op(Op.LocalGet);
						Enc.uleb(b, old);
						valueAs(i.args[1], ty);
						op(w ? Op.I64Add : Op.I32Add);
					} else
						valueAs(i.args[1], ty);
					op(w ? Op.I64Store : Op.I32Store);
					memarg(w ? 3 : 2, 0);
				}
				op(Op.LocalGet);
				Enc.uleb(b, old);
			case "fence":
			case "f32_to_f64":
				valueAs(i.args[0], I32);
				op(Op.F32ReinterpretI32);
				op(Op.F64PromoteF32);
			case "f64_to_f32":
				value(i.args[0]);
				op(Op.F32DemoteF64);
				op(Op.I32ReinterpretF32);
			case _:
				throw new Unsupported("wasm: unknown special " + name);
		}
	}
}
