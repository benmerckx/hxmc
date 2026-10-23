package hxmc.wasmgc;

import haxe.ds.Vector;
import hxmc.Buf;
import hxmc.Mir;
import hxmc.ir.Ir;
import hxmc.wasm.Enc;

private enum Ctx {
	CIf;
	CLoop(b:Int);
	CBlock(b:Int);
	CPlain;
}

// One function's object-level Mir (MirBuild.gc, after Inline, Escape and
// Opt) as a WasmGC function body (docs/plans/codegen.md, "Object-level Mir",
// stage 5). The control flow is structured as wasm/WasmGen structures the
// linear-memory Mir (Ramsey's "Beyond Relooper" over the dominator tree:
// merge children in blocks around their dominator, loop headers in loops,
// the others inlined at their branch); a try is a legacy try around its
// body (the dominator subtree of its first block), whose catch branches to
// the handler's block with the exception. Each value lives in a local of
// the wasm type its operation gives it (key: FuncGen's keys), never cast
// where it is set: a phi's is what its operands share, else eqref; a use
// casts to what it needs (the IR's unchecked casts make a value's static
// type no promise). The operations themselves are written by FuncGen, the
// IR walker's expressions: each one as the IR's expression or statement
// over locals that stand for its operands (synthetic locals, an IrNode's
// placeholders), so that WasmGC's representation (struct and array types,
// casts, the inline array and structural paths, the runtime's intrinsics)
// stays in one place.
class MirGen extends FuncGen {
	final mf:MFunc;
	var vals:Array<MIns>;
	var keys:Vector<String>; // a value's key (null: none: void, or a constant written where it is used)
	var locs:Vector<Int>; // a value's local (-1: none)
	var synth:Vector<Local>; // a value's synthetic local (made when an operation reads it)
	var stacked:Vector<Bool>; // a value left on the stack for its one use (stackify)
	var uses:Vector<Int>;
	var varLocal:Array<Int> = [];
	var varKey:Array<String> = [];
	var ctx:Array<Ctx> = [];
	// the control-flow graph
	var nblk = 0;
	var rpo:Vector<MBlock>;
	var rpoNum:Vector<Int>;
	var kids:Vector<Array<MBlock>>;
	var isLoop:Vector<Bool>;
	var isMerge:Vector<Bool>;
	var tryHandler:Vector<MBlock>; // a try body's first block -> the handler's
	var loopOf:hxmc.Cfg<MBlock>; // (the loops: Cfg.inLoop)
	// the objects made by their last field's initialization (enum values,
	// closures, boxes, anonymous structures, Array literals: their fields are
	// given to struct.new), by the New's value: their fields' values so far
	var pending = new Map<Int, Array<Int>>();

	public function new(m:GcModule, f:FuncInfo, mf:MFunc) {
		super(m, f);
		this.mf = mf;
	}

	public function emit():Buf {
		vals = mf.vals;
		var n = vals.length;
		keys = new Vector(n);
		locs = MFunc.ints(n, -1);
		synth = new Vector(n);
		// parameters (a typed one read as its type: cast once, as FuncGen)
		var paramLocal = [], paramKey = [];
		var shadows = [];
		for (i in 0...f.args.length) {
			var a = f.args[i];
			var idx = nparams++;
			paramLocal.push(idx);
			paramKey.push(m.paramKey(f, i));
			var k = m.precise(f) ? "" : i == 0 && f.selfClass != null ? "t" + m.classType(f.selfClass) : keyOf(a.ty);
			if (k.charAt(0) == "t") shadows.push({i: i, key: k});
		}
		for (s in shadows) {
			var l = nparams + extra.length;
			extra.push(s.key);
			localGet(paramLocal[s.i]);
			castTo(Std.parseInt(s.key.substr(1)));
			localSet(l);
			paramLocal[s.i] = l;
			paramKey[s.i] = s.key;
		}
		// the frame areas of the linear memory (Mem.stack, a struct's slot), as FuncGen
		for (b in mf.blocks)
			for (i in b.ins)
				if (i.op == IrNode && i.info.ex != null)
					switch i.info.ex {
						case ECallHost("hxmc_unsafe_Mem_stack" | "hxmc_unsafe_Mem_structSlot", _, _): hasFrame = true;
						case _:
					}
		if (hasFrame) {
			fp = nparams + extra.length;
			extra.push("i");
			spEntry = nparams + extra.length;
			extra.push("i");
		}
		cfg();
		uses = MFunc.ints(n, 0);
		for (x in rpo)
			for (i in x.ins)
				if (!i.dead) operands(i, v -> uses[v]++);
		// keys: parameters, then the operations' (phis to a fixpoint)
		for (x in rpo)
			for (i in x.ins) {
				if (i.dead) continue;
				if (i.op == Param) {
					keys[i.id] = paramKey[i.imm];
					locs[i.id] = paramLocal[i.imm];
				}
			}
		for (k in 0...mf.vars.length) {
			varKey.push(null);
			varLocal.push(-1);
		}
		var phis = [], copies = [];
		for (x in rpo)
			for (i in x.ins)
				if (!i.dead && i.op != Param) {
					if (i.op == Phi) phis.push(i) else keys[i.id] = keyOfIns(i);
					if (i.op == Copy) copies.push(i);
				}
		// (a copy has its operand's key: a phi's or a local's, known only here)
		function copyKeys():Bool {
			var changed = false;
			for (c in copies) {
				var k = valueKey(c.a);
				if (k != keys[c.id]) {
					keys[c.id] = k;
					changed = true;
				}
			}
			return changed;
		}
		var changed = true;
		while (changed) {
			changed = copyKeys();
			for (p in phis) {
				var k:Null<String> = null;
				for (a in p.args)
					k = lub(k, valueKey(a));
				if (k != keys[p.id]) {
					keys[p.id] = k;
					changed = true;
				}
			}
			// (a local out of SSA: what is stored into it)
			for (x in rpo)
				for (i in x.ins)
					if (!i.dead && i.op == VarSet) {
						var k = lub(varKey[i.info.n], valueKey(i.a));
						if (k != varKey[i.info.n]) {
							varKey[i.info.n] = k;
							changed = true;
						}
					}
			for (x in rpo)
				for (i in x.ins)
					if (!i.dead && i.op == VarGet && keys[i.id] != varKey[i.info.n]) {
						keys[i.id] = varKey[i.info.n];
						changed = true;
					}
		}
		for (p in phis)
			if (keys[p.id] == null || keys[p.id] == "n") keys[p.id] = repr(p.vty != null ? p.vty : TRef(RAny)) == "p" ? "p" : scalarKey(p.ty);
		for (k in 0...mf.vars.length) {
			var key = varKey[k];
			if (key == null || key == "n") key = scalarOr(repr(mf.vars[k]));
			varKey[k] = key;
			varLocal[k] = nparams + extra.length;
			extra.push(key);
		}
		for (x in rpo)
			for (i in x.ins)
				if (!i.dead && i.op == VarGet) keys[i.id] = varKey[i.info.n];
		while (copyKeys()) {}
		// locals (none for a value left on the stack)
		for (x in rpo)
			for (i in x.ins)
				if (!i.dead && keys[i.id] == "n" && i.op != Param && !isConst(i)) keys[i.id] = "p";
		stacked = new Vector(n);
		if (stackifyOn)
			for (x in rpo)
				stackify(x);
		assignLocals();
		doTree(mf.entry);
		if (repr(f.ret) != "v") op(0x00) else leave();
		op(0x0B);
		// the locals' declarations in front, then the frame's prologue (FuncGen's)
		var out = new Buf();
		Enc.uleb(out, extra.length);
		for (r in extra) {
			out.u8(1);
			switch r {
				case "i": out.u8(Enc.I32);
				case "f": out.u8(Enc.F64);
				case "l": out.u8(Enc.I64);
				case "p": out.u8(0x6D);
				case _:
					out.u8(0x63);
					Enc.sleb(out, Std.parseInt(r.substr(1)));
			}
		}
		if (hasFrame) {
			out.u8(0x23);
			Enc.uleb(out, m.spGlobal);
			out.u8(0x22);
			Enc.uleb(out, spEntry);
			out.u8(0x41);
			Enc.sleb(out, (frameSize + 15) & ~15);
			out.u8(0x6B);
			out.u8(0x22);
			Enc.uleb(out, fp);
			out.u8(0x24);
			Enc.uleb(out, m.spGlobal);
		}
		out.buf(b);
		return out;
	}

	// ---- keys

	static inline function repr(t:Ty):String
		return GcModule.repr(t);

	static inline function rOf(e:Ex):String
		return FuncGen.rOf(e);

	static inline function isConst(i:MIns):Bool
		return i.op == Const || i.op == ConstF;

	static function scalarKey(t:MTy):String
		return switch t {
			case I32: "i";
			case F64: "f";
			case I64: "l";
			case Void: null;
		};

	static function scalarOr(r:String):String
		return r == "v" ? "i" : r;

	// the least key of two (null: none yet; "n": null, under every reference)
	function lub(a:Null<String>, b:Null<String>):Null<String> {
		if (a == null || a == b) return b;
		if (b == null) return a;
		if (a == "n") return isRefKey(b) ? b : a;
		if (b == "n") return isRefKey(a) ? a : b;
		if (isRefKey(a) && isRefKey(b)) {
			if (a.charAt(0) == "t" && b.charAt(0) == "t") {
				var x = Std.parseInt(a.substr(1)), y = Std.parseInt(b.substr(1));
				if (m.isSubtype(x, y)) return b;
				if (m.isSubtype(y, x)) return a;
			}
			return "p";
		}
		return unsupported('a phi of $a and $b');
	}

	static inline function isRefKey(k:String):Bool
		return k == "p" || k == "n" || k.charAt(0) == "t";

	// a value's key where it is read (a constant's: its kind; a reference's null "n")
	function valueKey(v:Int):Null<String> {
		var i = vals[v];
		if (i.op == Const) return i.ty == I64 && (i.vty == null || Ir.isRef(i.vty)) && i.imm == 0 && i.imm2 == 0 && refNull(i) ? "n" : scalarKey(i.ty);
		if (i.op == ConstF) return "f";
		return keys[v];
	}

	// an I64 constant 0 that stands for null (MirBuild's ENull, Escape's zero of a
	// reference): its type when it has one, else how it is read
	function refNull(i:MIns):Bool
		return i.vty != null ? Ir.isRef(i.vty) : true;

	// the key an operation's value has (null: none)
	function keyOfIns(i:MIns):Null<String> {
		var o = i.info;
		return switch i.op {
			case Const | ConstF | Phi | Param: null;
			case Copy: valueKey(i.a);
			case Cmp | ArrayLength | EnumTag | TypeTest: "i";
			case Call:
				var g = funcOf(i);
				repr(g.ret) == "v" ? null : m.retKey(g);
			case New: "t" + newType(i);
			case NewArray: "t" + m.arrType(GcModule.elemKind(o.t));
			case GetField: getKey(i);
			case Box: "p";
			case Unbox | ArrayGet | AnonGet: scalarOr(repr(o.t));
			case VirtualCall | ClosureCall | AnonCall: repr(o.sig.ret) == "v" ? null : repr(o.sig.ret);
			case IrNode if (o.ex != null):
				var r = rOf(o.ex);
				r == "v" ? null : wtypeOf(i);
			case IrNode: null;
			case Catch: "p";
			case VarGet: null; // (from the local's, later)
			case _ if (i.isObj()): null;
			case _: scalarKey(i.ty);
		}
	}

	// an IrNode's static type, its placeholders bound to their values' keys
	function wtypeOf(i:MIns):String {
		bindKeys(i);
		return wtype(i.info.ex);
	}

	function bindKeys(i:MIns) {
		var ph = i.info.ph;
		for (k in 0...ph.length) {
			var key = valueKey(i.args[k]);
			localKey.set(ph[k].id, key == null || key == "n" ? repr(ph[k].ty) : key);
		}
	}

	// the struct type a New makes
	function newType(i:MIns):Int {
		var o = i.info;
		return switch o.name {
			case OInfo.NEW_OBJECT: m.classType(o.cls);
			case OInfo.NEW_ENUM: o.ctor.params.length == 0 ? m.enumTypeOf(o.ctor.en) : m.ctorType(o.ctor);
			case OInfo.NEW_CLOSURE: m.lambdaTypeOf(o.lambda);
			case OInfo.NEW_BOX: m.boxType(o.t);
			case OInfo.NEW_ANON: m.shapeType(o.shape);
			case OInfo.NEW_ARRAY: m.arrType(GcModule.elemKind(o.t));
			case x: unsupported("an allocation of " + x);
		}
	}

	// a field's index from its slot (MirBuild.at: an Int's or Bool's is twice it)
	static inline function idxOf(loc:Int, t:Ty):Int
		return t.match(TI32 | TBool) ? loc >> 1 : loc;

	function getKey(i:MIns):String {
		var o = i.info;
		return if (o.cls != null) m.fieldKey(o.cls, idxOf(o.loc, o.t)) else if (o.ctor != null) m.ctorParamKey(o.ctor, idxOf(o.loc, o.t)) else if (o.lambda != null)
			m.captureKey(o.lambda, idxOf(o.loc, o.t) - 1) else scalarOr(repr(o.t));
	}

	function funcOf(i:MIns):FuncInfo {
		var g = i.sym == null ? null : GcGen.funcBySym.get(i.sym);
		if (g == null) unsupported("a call of " + (i.sym == null ? "a function's address" : i.sym));
		return g;
	}

	// ---- operands

	static function operands(i:MIns, fn:Int->Void) {
		if (i.a >= 0) fn(i.a);
		if (i.b >= 0) fn(i.b);
		if (i.c >= 0) fn(i.c);
		for (x in i.args)
			fn(x);
	}

	// v's synthetic local: what an operation written by FuncGen reads it as
	function vlocal(v:Int):Local {
		var l = synth[v];
		if (l == null) {
			var i = vals[v];
			var t = i.vty != null ? i.vty : switch keys[v] {
				case "i": TI32;
				case "f": TF64;
				case "l": TI64;
				case _: TRef(RAny);
			};
			l = new Local(-100000 - v, "v" + v, t);
			synth[v] = l;
			local.set(l.id, locs[v]);
			localKey.set(l.id, keys[v]);
		}
		return l;
	}

	// v as an operand of an IR expression of type t: a constant as the IR's
	// literal (an Int64 one in a temporary), else its local
	function operand(v:Int, t:Ty):Ex {
		var i = vals[v];
		switch i.op {
			case Const if (i.ty == I32):
				return EInt(i.imm);
			case ConstF:
				return EF64(i.f);
			case Const if (Ir.isRef(t) || i.ty == I64 && (i.vty == null || Ir.isRef(i.vty)) && !t.match(TI64)):
				return ENull(Ir.isRef(t) ? t : TRef(RAny));
			case Const:
				var tmp = temp("l");
				constant(i, "l");
				localSet(tmp);
				var l = new Local(-200000 - tmp, "c", TI64);
				local.set(l.id, tmp);
				localKey.set(l.id, "l");
				temps.push({r: "l", i: tmp});
				return ELocal(l);
			case _:
				if (locs[v] < 0) unsupported("a value without a local (" + MFunc.insString(i) + ")");
				return ELocal(vlocal(v));
		}
	}

	var temps:Array<{r:String, i:Int}> = [];

	function releaseTemps() {
		for (t in temps)
			release(t.r, t.i);
		temps.resize(0);
	}

	// a constant of key k (a reference's null)
	function constant(i:MIns, k:String) {
		switch i.op {
			case ConstF:
				op(0x44);
				var bs = haxe.io.Bytes.alloc(8);
				bs.setDouble(0, i.f);
				b.bytes(bs);
			case Const if (i.ty == I32 && k == "l"): // (a rotation's count: MirWriter.rotation)
				op(0x42);
				Enc.sleb64(b, i.imm, i.imm < 0 ? -1 : 0);
			case Const if (i.ty == I32):
				i32(i.imm);
			case Const if (isRefKey(k)):
				op(0xD0);
				op(0x71);
			case Const:
				op(0x42);
				Enc.sleb64(b, i.imm, i.imm2);
			case _:
		}
	}

	// v's value on the stack as key k (cast to a type it may not be of)
	function push(v:Int, k:String) {
		var i = vals[v];
		if (isConst(i)) {
			constant(i, k);
			return;
		}
		if (!stacked[v]) { // (else on the stack already: stackify)
			if (locs[v] < 0) unsupported("a value without a local (" + MFunc.insString(i) + ")");
			localGet(locs[v]);
		}
		var vk = keys[v];
		if (k.charAt(0) == "t") {
			var t = Std.parseInt(k.substr(1));
			if (!(vk.charAt(0) == "t" && m.isSubtype(Std.parseInt(vk.substr(1)), t))) castTo(t);
		}
	}

	// the value on the stack into i's local (or dropped; or left there: stackify)
	function result(i:MIns) {
		if (stacked[i.id]) return;
		if (locs[i.id] >= 0) localSet(locs[i.id]) else if (keys[i.id] != null) op(0x1A);
	}

	// ---- locals

	static final shareOn = Sys.getEnv("HXMC_GC_SHARE") != "0";

	// Each value that needs one its local; a value made and used in one block
	// only (not by a phi, nor by an object's field initialization, which reads
	// it where the object is made) shares its local, of its key, with the
	// values of that kind that block-local before it and are dead by then.
	// (An engine's baseline compiler keeps the locals' state at every merge:
	// a large function's thousands of values cost it time and memory.)
	function assignLocals() {
		var n = vals.length;
		var useBlock = new Vector<MBlock>(n);
		var shared = new Vector<Bool>(n); // (a block-local value)
		var last = MFunc.ints(n, -1); // (its last use: an instruction's index in its block)
		// (not a phi, set on the edges into its block; nor the handler's
		// exception, nor an object its last field's initialization makes)
		for (x in rpo)
			for (i in x.ins)
				if (!i.dead) shared[i.id] = shareOn && i.op != Phi && i.op != Catch && i.op != New && i.op != NewArray;
		for (x in rpo) {
			var k = 0;
			for (i in x.ins) {
				if (i.dead) continue;
				var fieldInit = i.op == InitField || i.op == ArrayInit;
				operands(i, v -> {
					if (i.op == Phi || fieldInit || vals[v].block != x || useBlock[v] != null && useBlock[v] != x) shared[v] = false;
					useBlock[v] = x;
					last[v] = k;
				});
				if (i.op != Phi) k++;
			}
		}
		var free = new Map<String, Array<Int>>();
		for (x in rpo) {
			var k = 0;
			for (i in x.ins) {
				if (i.dead) continue;
				if (i.op != Phi) {
					// (what dies here gives its local back first: an operation reads
					// its operands before it writes its result)
					operands(i, v -> {
						if (shared[v] && locs[v] >= 0 && last[v] == k) {
							var key = keys[v];
							var l = free.get(key);
							if (l == null) free.set(key, l = []);
							if (l.indexOf(locs[v]) < 0) l.push(locs[v]);
						}
					});
				}
				if (!(i.op == Param || keys[i.id] == null || isConst(i) || stacked[i.id])) {
					var key = keys[i.id];
					var l = shared[i.id] ? free.get(key) : null;
					if (l != null && l.length > 0) locs[i.id] = l.pop() else {
						locs[i.id] = nparams + extra.length;
						extra.push(key);
					}
					// (never read: free again)
					if (shared[i.id] && last[i.id] < 0) {
						var fl = free.get(key);
						if (fl == null) free.set(key, fl = []);
						fl.push(locs[i.id]);
					}
				}
				if (i.op != Phi) k++;
			}
		}
	}

	// ---- stackify

	static final stackifyOn = Sys.getEnv("HXMC_GC_STACKIFY") != "0";

	// Values left on the wasm stack for their one use instead of in a local
	// (the code around them unchanged: a use pushes its operands in order, so
	// the leading ones may be there already). The use: an operation that
	// pushes its operands itself (rawOps); its leading operands made in its
	// block, used once, in that order, each by an operation that ends with its
	// result (producer); between the first and the use, what is left on the
	// stack for another use is used there too (the spans nest).
	function stackify(x:MBlock) {
		var pos = new Map<Int, Int>();
		var spans:Array<Int> = []; // (start, end) of each use's span
		var k = 0;
		for (u in x.ins) {
			if (u.dead || u.op == Phi || u.op == Param || isConst(u)) continue;
			pos.set(u.id, k);
			var ops = rawOps(u);
			if (ops != null) {
				var take = [];
				var last = -1;
				for (j in 0...ops.length) {
					var v = ops[j];
					var d = vals[v];
					if (isConst(d) || uses[v] != 1 || d.block != x || !pos.exists(v) || pos.get(v) <= last || !producer(d)) break;
					last = pos.get(v);
					take.push(v);
					// (a cast where it is pushed: only on top of the stack)
					if (needsCast(v, pushKey(u, j))) break;
				}
				// (none inside another use's span: that use would find it on top)
				for (j in 0...take.length) {
					var s = pos.get(take[j]);
					var inside = false;
					var q = 0;
					while (q < spans.length) {
						if (spans[q] < s && spans[q + 1] > s) inside = true;
						q += 2;
					}
					if (inside) {
						take.resize(j);
						break;
					}
				}
				if (take.length > 0) {
					spans.push(pos.get(take[0]));
					spans.push(k);
					for (v in take)
						stacked[v] = true;
				}
			}
			k++;
		}
	}

	// the values an operation pushes first, in order, when it pushes them
	// itself (null: none, or FuncGen writes it from locals)
	function rawOps(i:MIns):Null<Array<Int>> {
		return switch i.op {
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Rotr | Div | Rem | FAdd | FSub | FMul | FDiv: [i.a, i.b];
			case Not | FNeg | FSqrt | FAbs | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits | NullCheck | VarSet: [i.a];
			case Cmp:
				var ka = valueKey(i.a), kb = valueKey(i.b);
				if (ka != null && kb != null && (isRefKey(ka) || isRefKey(kb)) && (ka == "n" || kb == "n")) [ka == "n" ? i.b : i.a] else [i.a, i.b];
			case Select: [i.b, i.c, i.a];
			case Call: i.args.toArray();
			case Ret if (i.a >= 0): [i.a];
			case Br if (i.targets[0] != i.targets[1]): [i.a];
			case _: null;
		}
	}

	// the key the j-th of rawOps(u) is pushed as
	function pushKey(u:MIns, j:Int):String {
		return switch u.op {
			case Call: m.paramKey(funcOf(u), j);
			case Select: j < 2 ? keys[u.id] : "i";
			case Ret: m.retKey(f);
			case VarSet: varKey[u.info.n];
			case _: "i"; // (scalars, conditions, references as eqref: never cast)
		}
	}

	// whether push casts v to k
	function needsCast(v:Int, k:String):Bool {
		if (k.charAt(0) != "t") return false;
		var vk = keys[v];
		return !(vk.charAt(0) == "t" && m.isSubtype(Std.parseInt(vk.substr(1)), Std.parseInt(k.substr(1))));
	}

	// an operation that ends with its result (result, exResult), nothing after
	function producer(i:MIns):Bool {
		if (keys[i.id] == null) return false;
		return switch i.op {
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Rotr | Div | Rem | FAdd | FSub | FMul | FDiv | Neg | Not | FNeg | FSqrt | FAbs | SExt | ZExt
				| Trunc | I2F | F2I | BitsToF | FToBits | Cmp | Select | Call | GetField | EnumTag | TypeTest | Box | Unbox | VirtualCall | ClosureCall | AnonGet
				| AnonCall | ArrayLength | ArrayGet: true;
			case IrNode: i.info.ex != null;
			case _: false;
		}
	}

	// an IR expression's value into i's local (of its key: cast when typed)
	function exResult(i:MIns, e:Ex) {
		var k = keys[i.id];
		if (k != null && k.charAt(0) == "t") exprAs(e, Std.parseInt(k.substr(1))) else expr(e);
		releaseTemps();
		if (k == null) {
			if (rOf(e) != "v") op(0x1A);
			return;
		}
		result(i);
	}

	// ---- the control-flow graph (WasmGen's)

	function cfg() {
		for (x in mf.blocks) {
			if (x.id >= nblk) nblk = x.id + 1;
			for (s in x.succs)
				if (s.id >= nblk) nblk = s.id + 1;
			for (p in x.preds)
				if (p.id >= nblk) nblk = p.id + 1;
		}
		mf.edited();
		var g = mf.cfg();
		g.loops();
		if (g.irreducible) unsupported("an irreducible loop");
		loopOf = g;
		rpo = g.rpo;
		rpoNum = MFunc.ints(nblk, -1);
		for (k in 0...rpo.length)
			rpoNum[rpo[k].id] = k;
		kids = new Vector(nblk);
		for (k in 0...nblk)
			kids[k] = [];
		for (k in 1...rpo.length)
			kids[rpo[g.idom[k]].id].push(rpo[k]);
		isLoop = new Vector(nblk);
		isMerge = new Vector(nblk);
		tryHandler = new Vector(nblk);
		for (k in 0...rpo.length) {
			var x = rpo[k];
			if (g.loopHead[k] == k) isLoop[x.id] = true;
			var fwd = 0;
			var seen = new Map<Int, Bool>();
			for (p in x.preds) {
				var pk = rpoNum[p.id];
				if (pk >= 0 && pk < k && !seen.exists(p.id)) {
					seen.set(p.id, true);
					fwd++;
				}
			}
			if (fwd >= 2) isMerge[x.id] = true;
			if (x.handler) isMerge[x.id] = true;
			// (a loop's exit: after the loop, not inside it at its branch, so that
			// loops one after another do not nest, which an engine's baseline
			// compiler pays for at every level)
			for (p in x.preds) {
				var pk = rpoNum[p.id];
				if (pk >= 0 && pk < k && g.loopHead[pk] >= 0 && g.idom[k] == g.loopHead[pk] && !g.inLoop(k, g.loopHead[pk]) && p.term().op != Try) isMerge[x.id] = true;
			}
			var t = x.term();
			if (t != null && t.op == Try) {
				var tb = t.targets[0], hb = t.targets[1];
				if (isMerge[tb.id] && rpoNum[tb.id] > rpoNum[hb.id]) unsupported("a try body after its handler");
				tryHandler[tb.id] = hb;
			}
		}
	}

	// ---- structure

	function depth(c:Ctx):Int {
		var k = ctx.length;
		while (k-- > 0)
			if (Type.enumEq(ctx[k], c)) return ctx.length - 1 - k;
		return unsupported("a branch without its label (" + c + " in " + ctx + ")");
	}

	function brTo(c:Ctx) {
		op(0x0C);
		Enc.uleb(b, depth(c));
	}

	function doTree(x:MBlock) {
		var hb = tryHandler[x.id];
		if (hb != null) {
			// (with a linear memory: the stack pointer as here again where an
			// exception is caught, FuncGen.tryStmt's)
			var sp = -1;
			if (m.memory) {
				sp = temp("i");
				op(0x23);
				Enc.uleb(b, m.spGlobal);
				localSet(sp);
			}
			op(0x06);
			op(0x40);
			ctx.push(CPlain);
			treeBody(x);
			op(0x07);
			op(0);
			if (sp >= 0) {
				localGet(sp);
				op(0x24);
				Enc.uleb(b, m.spGlobal);
				release("i", sp);
			}
			// (the exception into the handler's Catch)
			var c = catchOf(hb);
			if (c != null && locs[c.id] >= 0) localSet(locs[c.id]) else op(0x1A);
			brTo(CBlock(hb.id));
			ctx.pop();
			op(0x0B);
			op(0x00);
		} else
			treeBody(x);
	}

	function catchOf(hb:MBlock):Null<MIns> {
		for (i in hb.ins)
			if (!i.dead && i.op == Catch) return i;
		return null;
	}

	function treeBody(x:MBlock) {
		var ys = [for (c in kids[x.id]) if (isMerge[c.id]) c];
		ys.sort((p, q) -> rpoNum[q.id] - rpoNum[p.id]);
		if (isLoop[x.id]) {
			// (the merge children outside the loop: in blocks around it)
			var k = rpoNum[x.id];
			var outs = [for (y in ys) if (!loopOf.inLoop(rpoNum[y.id], k)) y];
			var ins = [for (y in ys) if (loopOf.inLoop(rpoNum[y.id], k)) y];
			loopWithin(x, outs, ins, 0);
		} else
			nodeWithin(x, ys, 0);
	}

	function loopWithin(x:MBlock, outs:Array<MBlock>, ins:Array<MBlock>, k:Int) {
		if (k == outs.length) {
			op(0x03);
			op(0x40);
			ctx.push(CLoop(x.id));
			nodeWithin(x, ins, 0);
			ctx.pop();
			op(0x0B);
			op(0x00);
			return;
		}
		op(0x02);
		op(0x40);
		ctx.push(CBlock(outs[k].id));
		loopWithin(x, outs, ins, k + 1);
		ctx.pop();
		op(0x0B);
		doTree(outs[k]);
	}

	function nodeWithin(x:MBlock, ys:Array<MBlock>, k:Int) {
		if (k == ys.length) {
			mblock(x);
			return;
		}
		op(0x02);
		op(0x40);
		ctx.push(CBlock(ys[k].id));
		nodeWithin(x, ys, k + 1);
		ctx.pop();
		op(0x0B);
		doTree(ys[k]);
	}

	function isLabel(src:MBlock, dst:MBlock):Bool
		return rpoNum[dst.id] <= rpoNum[src.id] || isMerge[dst.id];

	function labelOf(src:MBlock, dst:MBlock):Ctx
		return isLoop[dst.id] && rpoNum[dst.id] <= rpoNum[src.id] ? CLoop(dst.id) : CBlock(dst.id); // (a loop's exit may come before a block of its loop)

	function doBranch(src:MBlock, dst:MBlock) {
		moves(src, dst);
		if (isLabel(src, dst)) brTo(labelOf(src, dst)) else doTree(dst);
	}

	function edgePhis(src:MBlock, dst:MBlock):Array<{phi:MIns, v:Int}> {
		var pi = dst.preds.indexOf(src);
		var out = [];
		for (i in dst.ins) {
			if (i.op != Phi) {
				if (!i.dead) break;
				continue;
			}
			if (i.dead || locs[i.id] < 0) continue;
			var v = i.args[pi];
			if (v == i.id || locs[v] == locs[i.id] && locs[v] >= 0) continue;
			out.push({phi: i, v: v});
		}
		return out;
	}

	function moves(src:MBlock, dst:MBlock) {
		var ps = edgePhis(src, dst);
		for (p in ps)
			push(p.v, keys[p.phi.id]);
		var k = ps.length;
		while (k-- > 0)
			localSet(locs[ps[k].phi.id]);
	}

	function mblock(x:MBlock) {
		// (the objects read or written as a class more than once here: cast once, castOperand)
		casts.clear();
		recv.clear();
		for (i in x.ins)
			if (!i.dead && (i.op == GetField || i.op == SetField) && i.info.cls != null)
				recv.set(i.a, recv.exists(i.a) ? recv.get(i.a) + 1 : 1);
		for (i in x.ins) {
			if (i.dead || i.op == Phi) continue;
			if (i.isTerm()) {
				term(x, i);
				return;
			}
			ins(i);
		}
		unsupported("a block without a terminator");
	}

	// The receiver of a field read or write, as an object of its class: an
	// untyped value (eqref: from Dynamic, an array of references, a structural
	// read) used so more than once in the block is cast once, into a local of
	// the class's type, which its other uses there read (the cast the field
	// access would make anyway: a value of another type traps there too)
	final casts = new Map<Int, Int>(); // value -> the local holding it cast, in this block
	final recv = new Map<Int, Int>(); // value -> its uses as a class's receiver in this block
	final castLocal = new Map<String, Int>(); // "value:type" -> its local (reused across blocks)

	function classOperand(v:Int, c:ClassInfo):Ex {
		var t = m.classType(c);
		var vk = valueKey(v);
		if (vk == null || vk.charAt(0) == "t" || isConst(vals[v]) || stacked[v] || locs[v] < 0 || !recv.exists(v) || recv.get(v) < 2)
			return operand(v, TRef(RObj(c)));
		var l = casts.get(v);
		if (l == null || localKeyOf(l) != "t" + t) {
			var ck = v + ":" + t;
			var cl = castLocal.get(ck);
			if (cl == null) {
				cl = nparams + extra.length;
				extra.push("t" + t);
				castLocal.set(ck, cl);
			}
			localGet(locs[v]);
			castTo(t);
			localSet(cl);
			casts.set(v, cl);
			l = cl;
		}
		var loc = new Local(-300000 - l, "c" + l, TRef(RObj(c)));
		local.set(loc.id, l);
		localKey.set(loc.id, "t" + t);
		return ELocal(loc);
	}

	inline function localKeyOf(l:Int):String
		return extra[l - nparams];

	// v as a condition: not zero (a reference: not null; Opt's condProp
	// branches on a value tested against 0 itself)
	function cond(v:Int) {
		var k = valueKey(v);
		if (k != null && isRefKey(k)) {
			push(v, "p");
			op(0xD1);
			op(0x45);
		} else if (k == "l") {
			push(v, "l");
			op(0x50);
			op(0x45);
		} else
			push(v, "i");
	}

	function term(x:MBlock, t:MIns) {
		switch t.op {
			case Jmp:
				doBranch(x, t.targets[0]);
			case Try:
				// (the body: its try is around its tree; the handler is a merge child)
				doBranch(x, t.targets[0]);
			case Unreachable:
				op(0x00);
			case Ret:
				if (t.a >= 0) push(t.a, m.retKey(f));
				leave();
				op(0x0F);
			case Br:
				var tt = t.targets[0], ff = t.targets[1];
				if (tt == ff) {
					doBranch(x, tt);
					return;
				}
				cond(t.a);
				if (edgePhis(x, tt).length == 0 && isLabel(x, tt)) {
					op(0x0D);
					Enc.uleb(b, depth(labelOf(x, tt)));
					doBranch(x, ff);
				} else if (edgePhis(x, ff).length == 0 && isLabel(x, ff)) {
					op(0x45);
					op(0x0D);
					Enc.uleb(b, depth(labelOf(x, ff)));
					doBranch(x, tt);
				} else {
					op(0x04);
					op(0x40);
					ctx.push(CIf);
					doBranch(x, tt);
					ctx.pop();
					op(0x0B);
					doBranch(x, ff);
				}
			case Switch:
				switchTerm(x, t);
			case _:
				unsupported("the terminator " + MFunc.opName(t.op));
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
		var span:Float = (hi : Float) - lo + 1;
		var dense = span > 0 && span <= 4.0 * cases.length + 16 && span < 65536;
		var k = dist.length;
		while (k-- > 0) {
			op(0x02);
			op(0x40);
			ctx.push(CPlain);
		}
		var labelIdx = (d:MBlock) -> dist.indexOf(d);
		if (dense) {
			push(t.a, "i");
			if (lo != 0) {
				i32(lo);
				op(0x6B);
			}
			var n = hi - lo + 1;
			var table = new Vector<Int>(n, labelIdx(def));
			for (ci in 0...cases.length)
				table[cases[ci] - lo] = labelIdx(t.targets[ci]);
			op(0x0E);
			Enc.uleb(b, n);
			for (e in table)
				Enc.uleb(b, e);
			Enc.uleb(b, labelIdx(def));
		} else {
			var s = temp("i");
			push(t.a, "i");
			localSet(s);
			for (ci in 0...cases.length) {
				localGet(s);
				i32(cases[ci]);
				op(0x46);
				op(0x0D);
				Enc.uleb(b, labelIdx(t.targets[ci]));
			}
			op(0x0C);
			Enc.uleb(b, labelIdx(def));
			release("i", s);
		}
		for (d in dist) {
			ctx.pop();
			op(0x0B);
			doBranch(x, d);
		}
	}

	// ---- instructions

	function ins(i:MIns) {
		var o = i.info;
		switch i.op {
			case Param | Const | ConstF | Catch:
			case Copy:
				if (locs[i.id] >= 0) {
					push(i.a, keys[i.id]);
					localSet(locs[i.id]);
				}
			case Add | Sub | Mul | And | Or | Xor | Shl | Sar | Shr | Rotr | Div | Rem:
				arith(i);
			case FAdd | FSub | FMul | FDiv:
				push(i.a, "f");
				push(i.b, "f");
				op(switch i.op {
					case FAdd: 0xA0;
					case FSub: 0xA1;
					case FMul: 0xA2;
					case _: 0xA3;
				});
				result(i);
			case Neg | Not | FNeg | FSqrt | FAbs | SExt | ZExt | Trunc | I2F | F2I | BitsToF | FToBits:
				unary(i);
			case Cmp:
				compare(i);
				result(i);
			case Select:
				var k = keys[i.id];
				push(i.b, k);
				push(i.c, k);
				cond(i.a);
				if (isRefKey(k)) {
					op(0x1C);
					op(1);
					op(0x6D);
				} else op(0x1B);
				result(i);
			case Call:
				// (as FuncGen's ECall: each argument as its parameter's key, the result the callee's)
				var g = funcOf(i);
				for (k in 0...i.args.length)
					push(i.args[k], m.paramKey(g, k));
				call(m.funcOf(g));
				if (repr(g.ret) != "v") result(i);
			case NullCheck:
				// (explicit null tests: the operations after it read the value unchecked)
				push(i.a, "p");
				call(m.nonNullAny());
			case New:
				newObj(i);
			case InitField:
				initField(i, i.a, i.b);
			case NewArray:
				if (o.n == 0) exResult(i, ENewArr(o.t, Vector.fromArrayCopy([]))) else pending.set(i.id, [for (_ in 0...o.n) -1]);
			case ArrayInit:
				initField(i, i.a, i.b);
			case GetField:
				objOp(() -> exResult(i, getEx(i)));
			case SetField:
				objOp(() -> {
					setStmt(i);
					releaseTemps();
				});
			case EnumTag:
				objOp(() -> exResult(i, EEnumTag(operand(i.a, TRef(REnum(o.en))), o.en)));
			case TypeTest:
				objOp(() -> exResult(i, EInstOf(o.cls, operand(i.a, TRef(RAny)))));
			case Box:
				exResult(i, EBox(o.t, operand(i.a, o.t)));
			case Unbox:
				exResult(i, EUnbox(o.t, operand(i.a, TRef(RAny))));
			case VirtualCall:
				var s = o.sig;
				objOp(() -> exResult(i, ECallDispatch(o.sel, s, Vector.fromArrayCopy([
					for (k in 0...i.args.length) operand(i.args[k], k == 0 ? TRef(RAny) : s.args[k - 1])
				]))));
			case ClosureCall:
				var s = o.sig;
				objOp(() -> exResult(i, ECallClos(s, operand(i.args[0], TRef(RClos(s))), Vector.fromArrayCopy([
					for (k in 1...i.args.length) operand(i.args[k], s.args[k - 1])
				]))));
			case AnonGet:
				objOp(() -> exResult(i, EAnonGet(o.name, o.t, operand(i.a, TRef(RAnon)), o.shape)));
			case AnonCall:
				var s = o.sig;
				objOp(() -> exResult(i, ECallAnon(o.name, s, operand(i.a, TRef(RAnon)), Vector.fromArrayCopy([
					for (k in 0...i.args.length) operand(i.args[k], s.args[k])
				]))));
			case ArrayLength:
				objOp(() -> exResult(i, EArrLen(operand(i.a, TRef(RArr(TRef(RAny)))))));
			case ArrayGet:
				var at = TRef(RArr(o.t));
				objOp(() -> exResult(i, o.flag ? EArrGet(o.t, operand(i.a, at), operand(i.b, TI32)) : EArrGetU(o.t, operand(i.a, at), operand(i.b, TI32))));
			case ArraySet:
				objOp(() -> {
					stmt(SArrSet(o.t, arrLocal(i.a), operand(i.b, TI32), operand(i.c, o.t)));
					releaseTemps();
				});
			case ArrayPush:
				objOp(() -> {
					stmt(SArrPush(o.t, arrLocal(i.a), operand(i.c, o.t)));
					releaseTemps();
				});
			case VarGet:
				if (locs[i.id] >= 0) {
					localGet(varLocal[o.n]);
					localSet(locs[i.id]);
				}
			case VarSet:
				push(i.a, varKey[o.n]);
				localSet(varLocal[o.n]);
			case IrNode:
				// (its placeholders: its operands' locals)
				var ph = o.ph;
				for (k in 0...ph.length) {
					var e = operand(i.args[k], ph[k].ty);
					switch e {
						case ELocal(l):
							local.set(ph[k].id, local.get(l.id));
							localKey.set(ph[k].id, localKey.get(l.id));
						case _:
							// (a literal: in a temporary of its kind)
							var r = rOf(e) == "v" ? "i" : rOf(e);
							var tmp = temp(r);
							expr(e);
							localSet(tmp);
							temps.push({r: r, i: tmp});
							local.set(ph[k].id, tmp);
							localKey.set(ph[k].id, r);
					}
				}
				if (o.ex != null) exResult(i, o.ex) else {
					stmt(o.stmt);
					releaseTemps();
				}
			case x:
				unsupported("the operation " + MFunc.opName(x));
		}
	}

	// an object operation written by FuncGen without its null tests (the
	// object-level Mir has them where they are needed: NullCheck)
	function objOp(write:Void->Void) {
		skipChecks = true;
		write();
		skipChecks = false;
	}

	// an Array's local (FuncGen's array stores take the array as a local)
	function arrLocal(v:Int):Local {
		var e = operand(v, TRef(RArr(TRef(RAny))));
		return switch e {
			case ELocal(l): l;
			case _: unsupported("an array store into a constant");
		}
	}

	function getEx(i:MIns):Ex {
		var o = i.info;
		var x = i.a;
		return if (o.cls != null) EField(o.cls, idxOf(o.loc, o.t), classOperand(x, o.cls)) else if (o.ctor != null)
			EEnumParam(o.ctor, idxOf(o.loc, o.t), operand(x, TRef(RCtor(o.ctor)))) else if (o.lambda != null)
			ECapture(o.lambda, idxOf(o.loc, o.t) - 1, operand(x, TRef(RAny))) else if (o.shape != null)
			EAnonGet(o.shape.fields[idxOf(o.loc, o.t)].name, o.t, operand(x, TRef(RAnon)), o.shape) else EBoxGet(o.t, operand(x, TRef(RBox(o.t))));
	}

	function setStmt(i:MIns) {
		var o = i.info;
		var x = i.a;
		if (o.cls != null) {
			var idx = idxOf(o.loc, o.t);
			stmt(SSetField(o.cls, idx, classOperand(x, o.cls), operand(i.b, o.t)));
		} else if (o.shape != null)
			stmt(SAnonSet(o.shape.fields[idxOf(o.loc, o.t)].name, o.t, operand(x, TRef(RAnon)), operand(i.b, o.t)));
		else if (o.ctor == null && o.lambda == null)
			stmt(SBoxSet(o.t, operand(x, TRef(RBox(o.t))), operand(i.b, o.t)));
		else
			unsupported("a store into an immutable field");
	}

	// a New: made here, or when its last field is given (pending)
	function newObj(i:MIns) {
		var o = i.info;
		var n = switch o.name {
			case OInfo.NEW_ENUM: o.ctor.params.length;
			case OInfo.NEW_CLOSURE: o.lambda.captures.length;
			case OInfo.NEW_BOX: 1;
			case OInfo.NEW_ANON: o.shape.fields.length;
			case _: 0;
		};
		if (n > 0) {
			pending.set(i.id, [for (_ in 0...n) -1]);
			return;
		}
		exResult(i, switch o.name {
			case OInfo.NEW_OBJECT: ENewObj(o.cls);
			case OInfo.NEW_ENUM: ENewEnum(o.ctor, Vector.fromArrayCopy([]));
			case OInfo.NEW_CLOSURE: ENewClos(o.lambda, Vector.fromArrayCopy([]));
			case OInfo.NEW_ANON: ENewAnon(o.shape, Vector.fromArrayCopy([]));
			case OInfo.NEW_ARRAY: ENewArr(o.t, Vector.fromArrayCopy([]));
			case x: unsupported("an allocation of " + x);
		});
	}

	// a field of a pending New (an element of an Array literal): the object
	// made at the last one
	function initField(i:MIns, obj:Int, v:Int) {
		var p = pending.get(obj);
		if (p == null) unsupported("a field initialized after its object was made (" + MFunc.insString(i) + ")");
		var no = vals[obj];
		var o = no.info;
		var k = switch no.op {
			case NewArray: i.info.loc;
			case _:
				switch o.name {
					case OInfo.NEW_CLOSURE: idxOf(i.info.loc, i.info.t) - 1;
					case OInfo.NEW_BOX: 0;
					case _: idxOf(i.info.loc, i.info.t);
				}
		};
		p[k] = v;
		for (x in p)
			if (x < 0) return;
		pending.remove(obj);
		var e = switch no.op {
			case NewArray: ENewArr(o.t, Vector.fromArrayCopy([for (x in p) operand(x, o.t)]));
			case _:
				switch o.name {
					case OInfo.NEW_ENUM: ENewEnum(o.ctor, Vector.fromArrayCopy([for (j in 0...p.length) operand(p[j], o.ctor.params[j])]));
					case OInfo.NEW_CLOSURE: ENewClos(o.lambda, Vector.fromArrayCopy([for (j in 0...p.length) operand(p[j], o.lambda.captures[j].ty)]));
					case OInfo.NEW_BOX: ENewBox(o.t, operand(p[0], o.t));
					case OInfo.NEW_ANON: ENewAnon(o.shape, Vector.fromArrayCopy([for (j in 0...p.length) operand(p[j], o.shape.fields[j].ty)]));
					case x: unsupported("an allocation of " + x);
				}
		};
		exResult(no, e);
	}

	// ---- arithmetic

	function arith(i:MIns) {
		var k = scalarKey(i.ty);
		push(i.a, k);
		push(i.b, k);
		var w = i.ty == I64;
		op(switch i.op {
			case Add: w ? 0x7C : 0x6A;
			case Sub: w ? 0x7D : 0x6B;
			case Mul: w ? 0x7E : 0x6C;
			case Div: w ? 0x7F : 0x6D;
			case Rem: w ? 0x81 : 0x6F;
			case And: w ? 0x83 : 0x71;
			case Or: w ? 0x84 : 0x72;
			case Xor: w ? 0x85 : 0x73;
			case Shl: w ? 0x86 : 0x74;
			case Sar: w ? 0x87 : 0x75;
			case Shr: w ? 0x88 : 0x76;
			case _: w ? 0x8A : 0x78; // rotr
		});
		result(i);
	}

	function unary(i:MIns) {
		var from = vals[i.a];
		switch i.op {
			case Neg:
				if (i.ty == I64) {
					op(0x42);
					op(0);
					push(i.a, "l");
					op(0x7D);
				} else {
					i32(0);
					push(i.a, "i");
					op(0x6B);
				}
			case Not:
				push(i.a, scalarKey(i.ty));
				if (i.ty == I64) {
					op(0x42);
					op(0x7F);
					op(0x85);
				} else {
					i32(-1);
					op(0x73);
				}
			case FNeg:
				push(i.a, "f");
				op(0x9A);
			case FSqrt:
				push(i.a, "f");
				op(0x9F);
			case FAbs:
				push(i.a, "f");
				op(0x99);
			case SExt:
				push(i.a, "i");
				op(0xAC);
			case ZExt:
				push(i.a, "i");
				op(0xAD);
			case Trunc:
				push(i.a, "l");
				op(0xA7);
			case I2F:
				if (from.ty == I64) {
					push(i.a, "l");
					op(0xB9);
				} else {
					push(i.a, "i");
					op(0xB7);
				}
			case F2I:
				push(i.a, "f");
				op(0xFC);
				op(i.ty == I64 ? 6 : 2);
			case BitsToF:
				push(i.a, "l");
				op(0xBF);
			case _:
				push(i.a, "f");
				op(0xBD);
		}
		result(i);
	}

	function compare(i:MIns) {
		var c:Cond = i.imm;
		var ka = valueKey(i.a), kb = valueKey(i.b);
		if (ka == null || kb == null) unsupported("a comparison of a value without a key");
		if (isRefKey(ka) || isRefKey(kb)) {
			// references: identity (a null side: ref.is_null)
			if (c != CEq && c != CNe) unsupported("an ordered comparison of references");
			if (ka == "n" || kb == "n") {
				push(ka == "n" ? i.b : i.a, "p");
				op(0xD1);
			} else {
				push(i.a, "p");
				push(i.b, "p");
				op(0xD3);
			}
			if (c == CNe) op(0x45);
			return;
		}
		var w = vals[i.a].ty;
		var k = scalarKey(w);
		push(i.a, k);
		push(i.b, k);
		op(switch w {
			case I32:
				switch c {
					case CEq: 0x46;
					case CNe: 0x47;
					case CLt: 0x48;
					case CULt: 0x49;
					case CGt: 0x4A;
					case CUGt: 0x4B;
					case CLe: 0x4C;
					case CULe: 0x4D;
					case CGe: 0x4E;
					case CUGe: 0x4F;
					case _: unsupported("a float condition on integers");
				}
			case I64:
				switch c {
					case CEq: 0x51;
					case CNe: 0x52;
					case CLt: 0x53;
					case CULt: 0x54;
					case CGt: 0x55;
					case CUGt: 0x56;
					case CLe: 0x57;
					case CULe: 0x58;
					case CGe: 0x59;
					case CUGe: 0x5A;
					case _: unsupported("a float condition on integers");
				}
			case _:
				switch c {
					case FEq | CEq: 0x61;
					case FNe | CNe: 0x62;
					case FLt | CLt: 0x63;
					case FGt | CGt: 0x64;
					case FLe | CLe: 0x65;
					case FGe | CGe: 0x66;
					case _: unsupported("an unsigned condition on floats");
				}
		});
	}
}
