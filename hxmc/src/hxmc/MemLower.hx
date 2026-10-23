package hxmc;

import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.MirWriter.BlockDefs;
import haxe.ds.Vector;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// The memory lowering: a function's object-level operations (Mir.Op from
// NullCheck on, made by MirBuild) become the memory-level Mir every back end
// takes (Isel, wasm/WasmGen, the Mir interpreter): objects' layouts as
// loads and stores at their offsets (hxmc.rt.Types), the nursery's inline
// allocation with its slow path's stub, write barriers and the release
// store of references, arrays' fast paths and the runtime's slow ones,
// inline caches for structural access, explicit null tests, the shadow
// stack around the slow paths of cold sites (docs/plans/codegen.md,
// "Object-level Mir").
//
// It runs after the object-level passes (Inline, Escape, Sroa, Opt,
// Frames), on what is left, its write barriers and spills only where
// they are still needed:
// each operation's instructions where it is (its blocks after the
// function's), the code after an operation that branches in its
// continuation (OInfo.cont: the phis there, a reference a cold site reloads
// after its slow path, get the value each edge's path has).
class MemLower extends MirWriter {
	static var noShadow = Sys.getEnv("HXMC_NOSHADOW") == "1";

	var icSym:String;

	public var icaches = 0; // inline caches made (bss: <name>__ic, IC_SIZE each)

	var repl:Array<Int> = []; // an operation's value -> the value lowered for it (-1: none)
	var nullBlocks = new Map<Int, MBlock>(); // per handler (OInfo.key): the block calling rt_null_access
	var slotOf = new Map<Int, Int>(); // AnonTest -> the slot its inline cache gave
	var arrData = new Map<Int, Int>(); // NewArray -> its storage, read again after a call (arrEpoch)
	var arrEpoch = new Map<Int, Int>();
	// calls during which a collection may move objects, so far (each one
	// lowered or passed through counts)
	var epoch = 0;

	override function call(sym:String, args:Vector<Int>, ret:MTy, noReturn = false):Int {
		var v = super.call(sym, args, ret, noReturn);
		if (!f.vals[v].keepsFrame) epoch++;
		return v;
	}

	override function callInd(fnv:Int, args:Vector<Int>, ret:MTy, ?argTys:Vector<MTy>):Int {
		epoch++;
		return super.callInd(fnv, args, ret, argTys);
	}
	// the operation being lowered: its static part, its cold site's
	// references (SSA variables of this pass), the frame's address, its
	// spill slots
	var op:OInfo;
	var spills:Array<Int> = [];
	var cold = false;
	var fr = -1;
	var spillBase = -1;

	public function new(p:Prep, abi:Abi, fn:FuncInfo, f:MFunc, icSym:String) {
		super(p, abi, fn);
		this.f = f;
		this.icSym = icSym;
	}

	// whether an operation's lowering branches and meets again: MirBuild
	// gives it a continuation (OInfo.cont), its last block here
	public static function branches(op:Op, o:OInfo):Bool {
		return switch op {
			case New | NewDyn | TypeTest | AnonGet | AnonCall | ArrayGet | ArraySet | ArrayPush | NewNArray | NArrayDyn | RefStore: true;
			case SetField: o.t.match(TRef(_)) && !o.flag && !o.fresh;
			case AnonStore: o.t.match(TRef(_));
			case ArrayInit: !o.t.match(TF64 | TI64 | TI32 | TBool);
			case NArrayInit: o.kind == Abi.AK_PTR;
			case NArraySet: o.flag;
			case _: false;
		}
	}

	public function run() {
		// (the blocks numbered from 0, as the SSA variables' tables are)
		for (k in 0...f.blocks.length) {
			f.blocks[k].id = k;
			defs.push(new BlockDefs());
			incomplete.push(null);
		}
		// (in reverse postorder: an operation another one's lowering needs, a
		// NewArray its ArrayInits', an AnonTest its AnonStore's, dominates it)
		f.edited();
		for (b in f.cfg().rpo.copy())
			lowerBlock(b);
		f.edited();
		// (the phis of the continuation of an operation a pass removed: plain ones)
		for (b in f.blocks)
			for (i in b.ins) {
				if (i.op != Phi) break;
				i.imm = 0;
			}
		// the operations' values replaced by their lowering's
		if (repl.length > 0)
			for (b in f.blocks)
				for (i in b.ins) {
					if (i.a >= 0) i.a = r(i.a);
					if (i.b >= 0) i.b = r(i.b);
					if (i.c >= 0) i.c = r(i.c);
					for (q in 0...i.args.length)
						i.args[q] = r(i.args[q]);
				}
	}

	inline function r(v:Int):Int {
		while (v >= 0 && v < repl.length && repl[v] >= 0)
			v = repl[v];
		return v;
	}

	function replace(v:Int, by:Int) {
		while (repl.length <= v)
			repl.push(-1);
		repl[v] = by;
	}

	// the operation's continuation as its lowering's last block
	inline function joinBlock():MBlock
		return op.cont;

	// a frame slot of the operation's
	inline function frameSlot(size:Int, align:Int):Int
		return f.slot(size, align);

	// the block's instructions again, its operations lowered where they are
	// (the code after one that branches in its last block)
	function lowerBlock(b:MBlock) {
		var list = b.ins;
		var any = false;
		for (i in list)
			if (i.isObj() && !i.dead) {
				any = true;
				break;
			}
		if (!any) return;
		b.ins = [];
		var succs = b.succs;
		b.succs = [];
		cur = b;
		var ended = false; // (its successors are the lowering's)
		var k = 0;
		while (k < list.length) {
			var x = list[k++];
			if (x.dead) continue;
			if (!x.isObj()) {
				x.block = cur;
				cur.ins.push(x);
				if (x.op == Call && !x.keepsFrame) epoch++;
				continue;
			}
			var o = op = x.info;
			curPos = x.pos;
			cold = o.cold;
			spills = [];
			if (cold)
				for (q in 0...o.nspill) {
					var v = newVar(I64);
					writeVar(v, cur, r(x.args[q]));
					spills.push(v);
				}
			fr = o.fr ? r(x.args[o.nspill]) : -1;
			spillNeed = null;
			cx = x;
			youngStart = o.young ? r(x.args[x.args.length - 2]) : -1;
			youngSize = o.young ? r(x.args[x.args.length - 1]) : -1;
			spillBase = o.spillBase;
			var c:Null<MBlock> = null, cphis = [], cins = [];
			if (x.isTerm()) {
				for (t in x.targets)
					t.preds.remove(b);
				ended = true;
			} else if (branches(x.op, o)) {
				c = o.cont;
				var j = list[list.length - 1];
				var direct = c != null && k < list.length && j.op == Jmp && j.targets[0] == c;
				// (what a pass put between the operation and its jump, which
				// runs after it: the start of its continuation)
				if (direct)
					for (q in k...list.length - 1)
						if (list[q].isObj() && !list[q].dead) direct = false;
				if (direct) {
					// its continuation (a cold site's references have their phis
					// there): entered by the lowering's edges, the code there
					// after the lowering's
					for (q in k...list.length - 1)
						if (!list[q].dead) cins.push(list[q]);
					k = list.length;
					c.preds.remove(b);
					for (i in c.ins)
						(i.op == Phi ? cphis : cins).push(i);
					c.ins = [];
					ended = true;
					if (cold && o.nspill > 0) {
						spillNeed = [for (q in 0...o.nspill) q == o.listIndex];
						for (phi in cphis)
							if (phi.imm > 0) spillNeed[phi.imm - 1] = true;
					}
				} else {
					if (c != null) throw "MemLower: " + MFunc.opName(x.op) + " apart from its continuation";
					// (none: one of its own, where the rest of the block goes)
					c = newBlock();
					c.sealed = true;
					op = o = o.copy(c);
				}
			}
			var v = lower(x, o);
			if (v >= 0 && v != x.id) {
				replace(x.id, v);
				var y = f.vals[v];
				if (y.vty == null) y.vty = x.vty;
			}
			if (c != null && cur != c) throw "MemLower: " + MFunc.opName(x.op) + " ends elsewhere than its continuation";
			if (cphis.length > 0 || cins.length > 0) {
				// its phis: one value per edge, the reference the edge's path has
				for (phi in cphis) {
					var one = phi.args[0];
					var args = new Vector<Int>(c.preds.length);
					for (q in 0...args.length)
						args[q] = phi.imm > 0 ? readVar(spills[phi.imm - 1], c.preds[q]) : one;
					phi.args = args;
					phi.imm = 0;
				}
				var ins = [for (i in c.ins) if (i.op == Phi) i];
				for (i in cphis)
					ins.push(i);
				for (i in c.ins)
					if (i.op != Phi) ins.push(i);
				for (i in cins)
					ins.push(i);
				c.ins = ins;
			}
		}
		if (ended) return;
		if (cur != b) {
			cur.succs = succs;
			for (s in succs)
				for (q in 0...s.preds.length)
					if (s.preds[q] == b) s.preds[q] = cur;
		} else b.succs = succs;
	}

	function lower(x:MIns, o:OInfo):Int {
		return switch x.op {
			case NullCheck:
				nullTest(r(x.a), o.key);
				-1;
			case New:
				var v = alloc(o.n, o.tindex, o.kind, o.zero);
				switch o.name {
					case OInfo.NEW_ENUM:
						if (o.next >= 0) storeM(Opt.MInit, 8, v, 8 * o.next, lconst(0, 0));
					case OInfo.NEW_CLOSURE:
						storeM(Opt.MInit, 8, v, 0, symAddr(p.funcSym(o.lambda.fn)));
					case OInfo.NEW_BOX:
						storeM(Opt.MInit, 8, v, 0, lconst(0, 0));
					case OInfo.NEW_ARRAY:
						// (an empty Array: no room, the empty storage of its kind)
						var k = arrKind(o.t);
						storeM(Opt.MInit, 4, v, 4, iconst(k));
						storeM(Opt.MInit, 8, v, 8, symAddr(MirBuild.EMPTY_ARRAY + k, 8));
					case _:
				}
				v;
			case NewDyn:
				allocDyn(r(x.a), r(x.b), r(x.c), o.zero);
			// (the field accesses rewritten in place: the same instruction)
			case InitField:
				var v = r(x.a);
				if (o.t != TVoid) access(x, Store, Opt.MInit, v, r(x.b), o.loc, o.t);
				if (o.next >= 0) storeM(Opt.MInit, 8, v, 8 * o.next, lconst(0, 0));
				-1;
			case GetField:
				o.t == TVoid ? iconst(0) : access(x, Load, Opt.MField, r(x.a), -1, o.loc, o.t);
			case SetField if (!o.t.match(TRef(_)) || o.flag):
				access(x, Store, Opt.MField, r(x.a), r(x.b), o.loc, o.t);
				-1;
			case SetField if (o.fresh):
				// (into a young object: no barrier, the store publishing what it stores)
				access(x, Store, Opt.MField, r(x.a), r(x.b), o.loc, o.t);
				x.release = true;
				-1;
			case SetField:
				storeSlot(r(x.a), o.loc, o.t, r(x.b), o.flag);
				-1;
			case FieldAddr:
				op2(Add, I64, r(x.a), lconst32(8 * o.loc));
			case EnumTag:
				enumTag(r(x.a), o.en);
			case TypeTest:
				instOf(r(x.a), o.cls);
			case Box:
				boxFrom(o.t, r(x.a));
			case Unbox:
				unboxTo(o.t, r(x.a));
			case VirtualCall:
				var xs = x.args.map(r);
				var row = symAddr(p.selectorSym(o.sel));
				var ti = op1(ZExt, I64, tindex(xs[0]));
				var fp = load(I64, 8, row, -8 * Abi.T_FIRST, false, ti, 8);
				callInd(fp, xs, MirBuild.mty(o.sig.ret), o.sig.args.map(MirBuild.mty));
			case ClosureCall:
				var xs = x.args.map(r);
				var s = o.sig;
				var fp = load(I64, 8, xs[0], 0);
				// (a struct result: the address of the caller's memory, last)
				var sr = s.ret.match(TStruct(_));
				var tys = new Vector<MTy>(s.args.length + (sr ? 2 : 1));
				tys[0] = I64;
				for (k in 0...s.args.length)
					tys[k + 1] = MirBuild.mty(s.args[k]);
				if (sr) tys[s.args.length + 1] = I64;
				callInd(fp, xs, MirBuild.mty(s.ret), tys);
			case AnonGet:
				anonGet(r(x.a), o.name, o.t, o.shape);
			case AnonTest:
				anonTest(x, o);
				-1;
			case AnonStore:
				anonStore(r(x.a), r(x.b), slotOf.get(x.c), o.t);
				-1;
			case AnonCall:
				callAnon(r(x.a), o.name, o.sig, x.args.map(r));
			case ArrayLength:
				loadM(Opt.MHdr, I32, 4, r(x.a), 0);
			case ArrayGet:
				arrGet(o.t, r(x.a), r(x.b), o.flag);
			case ArraySet:
				arrSet(o, r(x.a), r(x.b), r(x.c));
				-1;
			case ArrayPush:
				arrPush(o, r(x.a), r(x.c));
				-1;
			case NewArray:
				var k = arrKind(o.t);
				var v = call("hx_arr_new_n", vector(iconst(k), iconst(o.n)), I64);
				arrData.set(x.id, loadM(Opt.MHdr, I64, 8, v, 8));
				arrEpoch.set(x.id, epoch);
				v;
			case ArrayInit:
				var a = r(x.a);
				// (the storage read again after what may have collected since)
				if (arrEpoch.get(x.a) != epoch) {
					arrData.set(x.a, loadM(Opt.MHdr, I64, 8, a, 8));
					arrEpoch.set(x.a, epoch);
				}
				var d = arrData.get(x.a);
				var v = r(x.b);
				var i = o.loc;
				switch o.t {
					case TF64 | TI64: storeM(Opt.MElem, 8, d, 8 * i, v);
					case TI32: storeM(Opt.MElem, 4, d, 4 * i, v);
					case TBool: storeM(Opt.MElem, 1, d, i, v);
					case _: setPtr(d, op2(Add, I64, d, lconst32(8 * i)), v, Opt.MElem);
				}
				-1;
			case NewNArray:
				newNArray(o.kind, r(x.a));
			case NArrayInit:
				var v = r(x.a), e = r(x.b);
				var size = Abi.akSize(o.kind);
				if (o.kind == Abi.AK_PTR) setPtr(v, op2(Add, I64, v, lconst32(8 * o.loc)), e, Opt.MElem);
				else storeM(Opt.MElem, size, v, size * o.loc, e);
				-1;
			case NArrayLength:
				loadM(Opt.MConst, I32, 4, r(x.a), -4);
			case NArrayGet:
				var ix = index64(r(x.b));
				loadM(Opt.MElem, x.ty, o.n, r(x.a), 0, false, ix, o.n);
			case NArraySet:
				var a = r(x.a);
				var ix = index64(r(x.b));
				if (o.flag) nativeSetPtr
(a, op2(Add, I64, a, op2(Shl, I64, ix, iconst(3))), r(x.c));
				else storeM(Opt.MElem, o.n, a, 0, r(x.c), ix, o.n);
				-1;
			case NArrayDyn:
				narrayDyn(r(x.a), r(x.b), x.c < 0 ? -1 : r(x.c));
			case RefStore:
				var a = r(x.a);
				setPtr(a, op2(Add, I64, a, r(x.b)), r(x.c));
				-1;
			case _:
				throw "MemLower: " + MFunc.opName(x.op);
		}
	}

	// ---- object slots

	// field access x becomes the load or store of slot loc of type t
	// (value: the store's) where control is; a load's value is x's
	function access(x:MIns, op:Op, cls:Int, o:Int, value:Int, loc:Int, t:Ty):Int {
		var four = !t.match(TRef(_) | TF64 | TI64);
		x.op = op;
		x.ty = op == Load ? (t == TF64 ? F64 : four ? I32 : I64) : Void;
		x.info = null;
		x.a = o;
		x.b = -1;
		x.c = value;
		x.imm = four ? 4 * loc : 8 * loc;
		x.imm2 = 1;
		x.size = four ? 4 : 8;
		x.signed = false;
		x.mem = cls;
		if (x.pos == 0) x.pos = curPos;
		x.block = cur;
		cur.ins.push(x);
		return x.id;
	}

	function slotLoad(o:Int, loc:Int, t:Ty):Int
		return switch t {
			case TRef(_): loadM(Opt.MField, I64, 8, o, 8 * loc);
			case TF64: loadM(Opt.MField, F64, 8, o, 8 * loc);
			case TI64: loadM(Opt.MField, I64, 8, o, 8 * loc);
			case TVoid: iconst(0);
			case _: loadM(Opt.MField, I32, 4, o, 4 * loc);
		};

	// a store into a heap object; references go through the write barrier
	function storeSlot(o:Int, loc:Int, t:Ty, v:Int, isNull:Bool) {
		switch t {
			case TRef(_):
				if (isNull) storeM(Opt.MField, 8, o, 8 * loc, v) else setPtr(o, op2(Add, I64, o, lconst32(8 * loc)), v, Opt.MField);
			case TF64 | TI64: storeM(Opt.MField, 8, o, 8 * loc, v);
			case TVoid:
			case _: storeM(Opt.MField, 4, o, 4 * loc, v);
		}
	}

	// a store into a new (young) object: no barrier
	function storeInit(o:Int, loc:Int, t:Ty, v:Int) {
		switch t {
			case TRef(_) | TF64 | TI64: storeM(Opt.MInit, 8, o, 8 * loc, v);
			case TVoid:
			case _: storeM(Opt.MInit, 4, o, 4 * loc, v);
		}
	}

	// rt_set_ptr(obj, slot, val): the runtime's part (GcPaths.barrierSlow)
	// only for a young value stored into an object that is not young (a
	// value that is null or old, the common store into an old object, needs
	// nothing). The store publishes val (MIns.release): a thread that reads
	// the reference sees the object's initialising stores, as the reference
	// compiler's code may assume (OCaml's caml_modify is a release store,
	// "publication safety for newly-allocated objects"): upstream's parallel
	// phases read fields that other domains set meanwhile, such as Dce's
	// `Meta.has Meta.Used a.a_meta` before it takes the lock to add the entry.
	function setPtr(obj:Int, slot:Int, val:Int, cls = 0, last = true) {
		var prev = loadM(cls, I64, 8, slot, 0);
		storeM(cls, 8, slot, 0, val, -1, 1, true);
		var ys = youngStart, size = youngSize;
		if (ys < 0) {
			ys = loadM(Opt.MCallOnly, I64, 8, symAddr("rt_young_start"), 0);
			size = op2(Sub, I64, loadM(Opt.MCallOnly, I64, 8, symAddr("rt_young_end"), 0), ys);
		}
		var check = newBlock(), slow = newBlock(), done = last ? joinBlock() : newBlock();
		slow.cold = true;
		br(cmp(CULt, op2(Sub, I64, val, ys), size), check, done);
		seal(check);
		cur = check;
		br(cmp(CULt, op2(Sub, I64, obj, ys), size), done, slow);
		seal(slow);
		cur = slow;
		call("hxmc_barrier_slow", vector(obj, slot, val, prev), Void);
		jmp(done);
		seal(done);
		cur = done;
	}

	// Fixed arrays often outlive the values written into them. Avoid the
	// barrier call altogether when the new value is null or outside the nursery.
	function nativeSetPtr(obj:Int, slot:Int, val:Int, last = true)
		setPtr(obj, slot, val, Opt.MElem, last);

	// the nursery's bounds for the operation's write barrier, given by the
	// optimizer as its last arguments (OInfo.young: loaded where the store is,
	// shared and moved out of loops as other loads; -1: loaded here)
	var youngStart = -1;
	var youngSize = -1;

	var cx:MIns; // the operation being lowered

	// its k-th operand given by the optimizer (OInfo.ops: an array's header)
	inline function given(k:Int):Int
		return r(cx.args[op.ops + k]);

	// an index widened (given widened by the optimizer: Opt.operands)
	inline function index64(v:Int):Int
		return f.vals[v].ty == I64 ? v : op1(SExt, I64, v);

	function tindex(o:Int):Int
		return loadM(Opt.MConst, I32, 2, o, Abi.HDR_TINDEX);

	// an enum value's tag: its type index less a constant when the enum's
	// constructors' indices less their tags agree, else its type's tag
	function enumTag(o:Int, en:Null<EnumInfo>):Int {
		var base:Null<Int> = en == null || en.ctors.length == 0 ? null : en.ctors[0].tindex - en.ctors[0].tag;
		if (base != null)
			for (c in en.ctors)
				if (c.tindex - c.tag != base) base = null;
		if (base != null) return op2(Sub, I32, tindex(o), tyConst(en.ctors[0].tindex, -en.ctors[0].tag));
		var ti = op1(ZExt, I64, tindex(o));
		return loadM(Opt.MConst, I32, 4, symAddr("rt_types"), Abi.TYPE_TAG, false, op2(Mul, I64, ti, lconst32(Abi.TYPE_SIZE)), 1);
	}

	// hx_inst(o, lo, hi): o && KIND(o) == K_OBJ && lo <= TINDEX(o) <= hi
	function instOf(o:Int, c:ClassInfo):Int {
		var r = newVar(I32);
		writeVar(r, cur, iconst(0));
		var nn = newBlock(), join = joinBlock();
		br(cmp(CNe, o, lconst(0, 0)), nn, join);
		seal(nn);
		cur = nn;
		var t = tindex(o);
		// lo <= t <= hi as one unsigned comparison
		writeVar(r, cur, cmp(CULe, op2(Sub, I32, t, tyConst(c.tindex)), idConst(p.spanSym(c), 0)));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}

	function unboxTo(t:Ty, v:Int):Int
		return switch t {
			case TI32: call("hx_unbox_int", vector(v), I32);
			case TBool: call("hx_unbox_bool", vector(v), I32);
			case TF64: call("hx_unbox_float", vector(v), F64);
			case TI64: call("hx_unbox_i64", vector(v), I64);
			case _: v;
		};

	function boxFrom(t:Ty, v:Int):Int
		return switch t {
			case TI32: call("hx_box_int", vector(v), I64);
			case TBool: call("hx_box_bool", vector(v), I64);
			case TF64: call("hx_box_float", vector(v), I64);
			case TI64: call("hx_box_i64", vector(v), I64);
			case _: v;
		};

	// ---- null access (docs/hxmc.md, "Null access")

	// v is about to be dereferenced: null branches to the throw (a call of
	// rt_null_access per try, which the tests of the code it covers share:
	// on WebAssembly, a try's body is wrapped as the dominator subtree of its
	// first block, so a block shared across tries would be outside them)
	function nullTest(v:Int, key:Int) {
		var bad = nullBlock(key);
		var ok = newBlock();
		br(cmp(CEq, v, lconst(0, 0)), bad, ok);
		seal(ok);
		cur = ok;
	}

	function nullBlock(key:Int):MBlock {
		var b = nullBlocks.get(key);
		if (b != null) return b;
		b = newBlock();
		b.cold = true;
		nullBlocks.set(key, b);
		var save = cur;
		cur = b;
		call("rt_null_access", vector(), Void, true);
		add(mk(Unreachable, Void));
		seal(b); // (it reads no variable: its predecessors may come later)
		cur = save;
		return b;
	}

	// ---- allocation

	// the allocation slow path's stubs: hxmc_new$<header low word>$<type symbol or #index>$<bytes>
	public static inline var ALLOC_STUB = "hxmc_new$";

	// an object of n slots: inline bump allocation; the slow path collects.
	// zero: the slots must read as zeros (Mem.alloc), else every slot is
	// written before it is read (Mem.allocRaw). The runtime zeroes the nursery
	// in bulk, so neither stores zeros; they compare different limits, which
	// differ with RT_VERIFY=1 (Gc.hx: zeroing allocations then take the slow
	// path). At a cold site the live references are stored on the shadow
	// stack around the slow call only
	function alloc(n:Int, tidx:Int, kind:Int, zero:Bool):Int {
		var bytes = 8 * (n + 1);
		var ptr = tlsLoad("rt_young_ptr");
		var lim = tlsLoad(zero ? "rt_young_limit" : "rt_young_rlimit");
		var res = newVar(I64);
		var fast = newBlock(), slow = newBlock(), join = joinBlock();
		slow.cold = true;
		br(cmp(CGe, op2(Sub, I64, lim, ptr), lconst32(bytes)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		tlsStore("rt_young_ptr", op2(Add, I64, ptr, lconst32(bytes)));
		// (the header, hxmc.rt.Types: K_OBJ a record, its type index, its slots,
		// its hash 0; else an array of n 8-byte slots, its type index, its
		// words, its length)
		var record = kind == Abi.K_OBJ;
		var flags = (n < 0xFFFF ? n : 0xFFFF) << 16;
		storeM(Opt.MInit, 4, ptr, 0, tyConst(tidx, flags));
		storeM(Opt.MInit, 4, ptr, 4, iconst(record ? 0 : n));
		var o = op2(Add, I64, ptr, lconst32(8));
		writeVar(res, cur, o);
		jmp(join);
		cur = slow;
		var sp = spillOpen(cold, 0);
		// (the header is assembled in the runtime, rthxmc.c; a stub per
		// header and size passes it, DataGen.allocStubs: one call here)
		var ts = p.tySym(tidx);
		var r = call(ALLOC_STUB + (record ? 0 : n) + "$" + (ts != null ? ts : "#" + (record ? tidx : tidx | flags)) + "$" + bytes, vector(), I64);
		spillClose(sp);
		writeVar(res, cur, r);
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	// Mem.alloc: an object of a run-time size (n slots), type index and kind;
	// zero as for alloc
	// an object of n slots, its header's words w0 (the type index first) and
	// w1 (hxmc.rt.Types), as alloc's; the slow path assembles it from them
	// and the bytes (GcPaths)
	function allocDyn(n:Int, w0:Int, w1:Int, zero:Bool, last = true):Int {
		var n64 = op1(ZExt, I64, n);
		var bytes = op2(Shl, I64, op2(Add, I64, n64, lconst(1, 0)), lconst(3, 0));
		var ptr = tlsLoad("rt_young_ptr");
		var lim = tlsLoad(zero ? "rt_young_limit" : "rt_young_rlimit");
		var res = newVar(I64);
		var fast = newBlock(), slow = newBlock(), join = last ? joinBlock() : newBlock();
		slow.cold = true;
		br(cmp(CGe, op2(Sub, I64, lim, ptr), bytes), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		tlsStore("rt_young_ptr", op2(Add, I64, ptr, bytes));
		storeM(Opt.MInit, 4, ptr, 0, w0);
		storeM(Opt.MInit, 4, ptr, 4, w1);
		writeVar(res, cur, op2(Add, I64, ptr, lconst32(8)));
		jmp(join);
		cur = slow;
		var sp = spillOpen(cold, 0);
		var r = call("hxmc_alloc_slow", vector(w1, w0, op1(Trunc, I32, bytes)), I64);
		spillClose(sp);
		writeVar(res, cur, r);
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	// stores the cold site's references in a pushed area, or the frame's
	// spill slots (-1: none; list: whether there is a list, possibly empty,
	// with extra slots after it)
	function spillOpen(list:Bool, extra:Int):Int {
		var n = 0;
		for (k in 0...spills.length)
			if (spillNeeded(k)) n++;
		if (!list || n + extra == 0) return -1;
		if (spillBase >= 0) {
			var area = op2(Add, I64, fr, lconst32(8 * spillBase));
			for (k in 0...spills.length)
				if (spillNeeded(k)) storeM(Opt.MFrame, 8, area, 8 * k, readVar(spills[k], cur));
			return area;
		}
		var sp = tlsLoad("rt_sp");
		var top = op2(Add, I64, sp, lconst32(8 * (spills.length + extra)));
		tlsStore("rt_sp", top);
		raiseHw(top);
		for (k in 0...spills.length)
			if (spillNeeded(k)) store(8, sp, 8 * k, readVar(spills[k], cur));
		return sp;
	}

	function spillClose(sp:Int) {
		if (sp < 0) return;
		for (k in 0...spills.length)
			if (spillNeeded(k)) writeVar(spills[k], cur, spillBase >= 0 ? loadM(Opt.MFrame, I64, 8, sp, 8 * k) : load(I64, 8, sp, 8 * k));
		if (spillBase < 0) tlsStore("rt_sp", sp);
	}

	// the cold site's references read after it (its continuation's phis) or
	// handed to the runtime (an array store's array): the others are not
	// spilled (a slot left as it is holds null or a valid reference: rt_sp_hw)
	var spillNeed:Null<Array<Bool>> = null;

	inline function spillNeeded(k:Int):Bool
		return spillNeed == null || spillNeed[k];

	// ---- arrays

	static function arrKind(t:Ty):Int
		return switch t {
			case TI32: Abi.AK_I32;
			case TBool: Abi.AK_BOOL;
			case TF64: Abi.AK_F64;
			case TI64: Abi.AK_I64;
			case _: Abi.AK_PTR;
		};

	// (an Array's storage is a NativeArray of its kind: its length the
	// capacity, then the elements, a Bool one byte; Boxes)
	static function elemSize(t:Ty):Int
		return switch t {
			case TBool: 1;
			case TI32: 4;
			case _: 8;
		};

	function bits64(t:Ty, v:Int):Int
		return switch t {
			case TF64: op1(FToBits, I64, v);
			case TI32 | TBool: op1(ZExt, I64, v);
			case _: v;
		};

	// the address of the slot holding the array (its local's shadow-stack
	// slot, or its place in the cold site's spill area)
	function arrSlot(o:OInfo, av:Int, sp:Int):Int {
		if (o.rootSlot >= 0) return op2(Add, I64, fr, lconst32(8 * o.rootSlot));
		if (noShadow && (sp < 0 || o.listIndex < 0)) {
			// (measurement: a frame slot holding the array; nothing collects)
			var addr = stackAddr(frameSlot(8, 8));
			store(8, addr, 0, av);
			return addr;
		}
		if (sp < 0 || o.listIndex < 0) throw new MirBuild.Unsupported("array local neither rooted nor spilled");
		return op2(Add, I64, sp, lconst32(8 * o.listIndex));
	}

	function arrSet(o:OInfo, av:Int, iv:Int, vv:Int) {
		var elem = o.t;
		var k = arrKind(elem);
		var fast = newBlock(), slow = newBlock(), join = joinBlock(), chk = newBlock();
		slow.cold = true;
		var pre = o.ops >= 0;
		var kind = pre ? given(0) : loadM(Opt.MHdr, I32, 4, av, 4);
		var len = pre ? given(1) : loadM(Opt.MHdr, I32, 4, av, 0);
		var d = pre ? given(2) : loadM(Opt.MHdr, I64, 8, av, 8);
		br(cmp(CEq, kind, iconst(k)), chk, slow);
		seal(chk);
		cur = chk;
		br(cmp(CULt, iv, len), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		var ix = pre ? given(3) : op1(SExt, I64, iv);
		if (k == Abi.AK_PTR) {
			setPtr(d, op2(Add, I64, d, op2(Shl, I64, ix, iconst(3))), vv, Opt.MElem, false);
		} else storeM(Opt.MElem, elemSize(elem), d, 0, vv, ix, elemSize(elem));
		jmp(join);
		cur = slow;
		if (k == Abi.AK_PTR) {
			// the value is rooted in a pushed slot (after the spilled references)
			var n = spills.length;
			var sp = spillOpen(true, 1);
			store(8, sp, 8 * n, vv);
			call("hx_aset_slow", vector(arrSlot(o, av, sp), iv, iconst(k), op2(Add, I64, sp, lconst32(8 * n))), Void);
			spillClose(sp);
		} else {
			var sp = spillOpen(cold, 0);
			call("hx_aset_slow", vector(arrSlot(o, av, sp), iv, iconst(k), bits64(elem, vv)), Void);
			spillClose(sp);
		}
		jmp(join);
		seal(join);
		cur = join;
	}

	function arrPush(o:OInfo, av:Int, vv:Int) {
		var elem = o.t;
		var k = arrKind(elem);
		var fast = newBlock(), slow = newBlock(), join = joinBlock(), c1 = newBlock();
		slow.cold = true;
		var pre = o.ops >= 0;
		br(cmp(CEq, pre ? given(0) : loadM(Opt.MHdr, I32, 4, av, 4), iconst(k)), c1, slow);
		seal(c1);
		cur = c1;
		// (the storage's length, the capacity, never changes; one without
		// room is the empty one)
		var d = pre ? given(1) : loadM(Opt.MHdr, I64, 8, av, 8);
		var len = pre ? given(2) : loadM(Opt.MHdr, I32, 4, av, 0);
		br(cmp(CULt, len, loadM(Opt.MConst, I32, 4, d, -4)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		var ix = op1(SExt, I64, len);
		if (k == Abi.AK_PTR) setPtr(d, op2(Add, I64, d, op2(Shl, I64, ix, iconst(3))), vv, Opt.MElem, false) else storeM(Opt.MElem, elemSize(elem), d, 0, vv, ix, elemSize(elem));
		storeM(Opt.MHdr, 4, av, 0, op2(Add, I32, len, iconst(1)));
		jmp(join);
		cur = slow;
		if (k == Abi.AK_PTR) {
			var n = spills.length;
			var sp = spillOpen(true, 1);
			store(8, sp, 8 * n, vv);
			call("hx_apush_slow", vector(arrSlot(o, av, sp), iconst(k), op2(Add, I64, sp, lconst32(8 * n))), I32);
			spillClose(sp);
		} else {
			var sp = spillOpen(cold, 0);
			call("hx_apush_slow", vector(arrSlot(o, av, sp), iconst(k), bits64(elem, vv)), I32);
			spillClose(sp);
		}
		jmp(join);
		seal(join);
		cur = join;
	}

	function arrGet(elem:Ty, av:Int, iv:Int, checked:Bool):Int {
		var k = arrKind(elem);
		var t = MirBuild.mty(elem);
		var res = newVar(t);
		var fast = newBlock(), slow = newBlock(), join = joinBlock();
		slow.cold = true;
		// the header is read before the checks (every array has one): later
		// accesses the first dominates reuse it (Opt)
		var pre = op.ops >= 0;
		var kind = pre ? given(0) : loadM(Opt.MHdr, I32, 4, av, 4);
		var len = checked ? (pre ? given(1) : loadM(Opt.MHdr, I32, 4, av, 0)) : -1;
		var d = pre ? given(checked ? 2 : 1) : loadM(Opt.MHdr, I64, 8, av, 8);
		if (checked) {
			var chk = newBlock();
			br(cmp(CEq, kind, iconst(k)), chk, slow);
			seal(chk);
			cur = chk;
			br(cmp(CULt, iv, len), fast, slow);
		} else br(cmp(CEq, kind, iconst(k)), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		writeVar(res, cur, loadM(Opt.MElem, t, elemSize(elem), d, 0, false, pre ? given(checked ? 3 : 2) : op1(SExt, I64, iv), elemSize(elem)));
		jmp(join);
		cur = slow;
		var name = switch k {
			case Abi.AK_I32 | Abi.AK_BOOL: "hx_aget_i_slow";
			case Abi.AK_F64: "hx_aget_f_slow";
			case Abi.AK_I64: "hx_aget_l_slow";
			case _: "hx_aget_p_slow";
		};
		writeVar(res, cur, call(name, vector(av, iv), t));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	// NativeArray storage of kind k and n elements: 1 to the most a header
	// can count by one unsigned test; none: the empty array of the kind
	// (MirBuild.EMPTY_ARRAY); else hx_narray_bad_length
	function newNArray(k:Int, n:Int):Int {
		var res = newVar(I64);
		var valid = newBlock(), other = newBlock(), empty = newBlock(), invalid = newBlock(), join = joinBlock();
		other.cold = true;
		br(cmp(CULt, op2(Sub, I32, n, iconst(1)), iconst(Abi.akMax(k))), valid, other);
		seal(other);
		cur = other;
		br(cmp(CEq, n, iconst(0)), empty, invalid);
		seal(invalid);
		cur = invalid;
		var invalidSp = spillOpen(cold, 0);
		call("hx_narray_bad_length", vector(), Void);
		spillClose(invalidSp);
		jmp(empty);
		seal(empty);
		cur = empty;
		writeVar(res, cur, symAddr(MirBuild.EMPTY_ARRAY + k, 8));
		jmp(join);
		seal(valid);
		cur = valid;
		// (the elements' words; the header holds the length, the type the kind)
		var words = Abi.akSize(k) == 1 ? op2(Shr, I32, op2(Add, I32, n, iconst(7)), iconst(3))
			: k == Abi.AK_I32 ? op2(Shr, I32, op2(Add, I32, n, iconst(1)), iconst(1)) : n;
		var a = allocDyn(words, arrWord(iconst(MirBuild.naType(k)), words), n, true, false);
		writeVar(res, cur, a);
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	// an element of a NativeArray seen as Dynamic (FnLower.nativeRead): of
	// reference storage directly, else through the runtime (rt/NArray's
	// hx_narray_get_slow, hx_narray_set_slow: the other kinds, wrappers). A
	// wrapper's kind changes, but never to AK_PTR, so the test may be shared
	// as that of a constant. At a cold site (Facts.markCold), the live
	// references are spilled around that call only (v: the value set, -1:
	// a read)
	function narrayDyn(a:Int, i:Int, v:Int):Int {
		var get = v < 0;
		var xs = get ? vector(a, i) : vector(a, i, v);
		var r = get ? newVar(I64) : -1;
		var fast = newBlock(), slow = newBlock(), join = joinBlock();
		br(cmp(CEq, tindex(a), iconst(MirBuild.naType(Abi.AK_PTR))), fast, slow);
		seal(fast);
		seal(slow);
		cur = fast;
		var ix = op1(SExt, I64, xs[1]);
		if (get) writeVar(r, cur, loadM(Opt.MElem, I64, 8, a, 0, false, ix, 8));
		else nativeSetPtr(a, op2(Add, I64, a, op2(Shl, I64, ix, iconst(3))), xs[2], false);
		jmp(join);
		cur = slow;
		var sp = spillOpen(cold, 0);
		var c = call(get ? "hx_narray_get_slow" : "hx_narray_set_slow", xs, get ? I64 : Void);
		spillClose(sp);
		if (get) writeVar(r, cur, c);
		jmp(join);
		seal(join);
		cur = join;
		return get ? readVar(r, cur) : -1;
	}

	// ---- structural access

	function icache():Int {
		var k = icaches++;
		return symAddr(icSym, Abi.IC_SIZE * k);
	}

	// rt_ic: the site's cache entry for the object's type (fid: a value)
	function ic(o:Int, fid:Int, ti = -1):Int {
		var c = icache();
		var res = newVar(I64);
		writeVar(res, cur, c);
		var miss = newBlock(), join = newBlock();
		miss.cold = true;
		br(cmp(CNe, load(I32, 4, c, 0), ti >= 0 ? ti : tindex(o)), miss, join);
		seal(miss);
		cur = miss;
		writeVar(res, cur, call("rt_icache_miss", vector(o, fid, c), I64));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	function kindMatch(c:Int, t:Ty):Int {
		var kind = load(I32, 1, c, Abi.IC_KIND);
		return switch t {
			case TI32 | TBool:
				var r = newVar(I32);
				writeVar(r, cur, cmp(CEq, kind, iconst("i".code)));
				var no = newBlock(), join = newBlock();
				br(readVar(r, cur), join, no);
				seal(no);
				cur = no;
				writeVar(r, cur, cmp(CEq, kind, iconst("b".code)));
				jmp(join);
				seal(join);
				cur = join;
				readVar(r, cur);
			case TF64: cmp(CEq, kind, iconst("f".code));
			case TI64: cmp(CEq, kind, iconst("l".code));
			case _: cmp(CEq, kind, iconst("p".code));
		}
	}

	// a field at a dynamic location (rt_icache.slot - 1)
	function slotLoadDyn(o:Int, loc:Int, t:Ty):Int {
		var ix = op1(SExt, I64, loc);
		return switch t {
			case TRef(_) | TI64: loadM(Opt.MField, I64, 8, o, 0, false, ix, 8);
			case TF64: loadM(Opt.MField, F64, 8, o, 0, false, ix, 8);
			case _: loadM(Opt.MField, I32, 4, o, 0, false, ix, 4);
		}
	}

	function anonGet(o:Int, name:String, t:Ty, hint:Null<ShapeInfo>):Int {
		var fid = fidConst(name);
		var mt = MirBuild.mty(t);
		var res = newVar(mt);
		var join = joinBlock();
		var ti = -1; // (the type index the hint's test read, which the cache's test reuses)
		if (hint != null && hint.tindex >= 0) {
			var direct = newBlock(), other = newBlock();
			other.cold = true;
			ti = tindex(o);
			br(cmp(CEq, ti, tyConst(hint.tindex)), direct, other);
			seal(direct);
			seal(other);
			cur = direct;
			var i = hint.slot(name) - 1;
			writeVar(res, cur, slotLoad(o, hint.locs[i], t));
			jmp(join);
			cur = other;
			coldNew = true;
		}
		var c = ic(o, fid, ti);
		var hit = newBlock(), miss = newBlock(), chk = newBlock();
		miss.cold = true;
		var slot = load(I32, 4, c, Abi.IC_SLOT);
		br(cmp(CGt, slot, iconst(0)), chk, miss);
		seal(chk);
		cur = chk;
		br(kindMatch(c, t), hit, miss);
		seal(hit);
		seal(miss);
		cur = hit;
		writeVar(res, cur, slotLoadDyn(o, op2(Sub, I32, slot, iconst(1)), t));
		jmp(join);
		cur = miss;
		writeVar(res, cur, unboxTo(t, call("hx_anon_get_slow", vector(o, fid), I64)));
		jmp(join);
		coldNew = false;
		seal(join);
		cur = join;
		return readVar(res, cur);
	}

	// a structural field write's test (MirBuild.anonSet made the hit, miss
	// and join blocks after it, the hit's store and the miss's call): the
	// inline cache's entry has a slot of the field's kind
	function anonTest(x:MIns, o:OInfo) {
		var hit = x.targets[0], miss = x.targets[1];
		var c = ic(r(x.a), r(x.b));
		var chk = newBlock();
		var slot = load(I32, 4, c, Abi.IC_SLOT);
		br(cmp(CGt, slot, iconst(0)), chk, miss);
		seal(chk);
		cur = chk;
		br(kindMatch(c, o.t), hit, miss);
		slotOf.set(x.id, slot);
	}

	function anonStore(o:Int, v:Int, slot:Int, t:Ty) {
		var loc = op1(SExt, I64, op2(Sub, I32, slot, iconst(1)));
		switch t {
			case TRef(_): setPtr(o, op2(Add, I64, o, op2(Shl, I64, loc, iconst(3))), v, Opt.MField);
			case TF64 | TI64: storeM(Opt.MField, 8, o, 0, v, loc, 8);
			case _: storeM(Opt.MField, 4, o, 0, v, loc, 4);
		}
	}

	function callAnon(o:Int, name:String, s:SigInfo, xs:Vector<Int>):Int {
		var fid = fidConst(name);
		var rt = MirBuild.mty(s.ret);
		// (the method's or the closure's arguments: the receiver first)
		var argTys = new Vector<MTy>(s.args.length + 1);
		argTys[0] = I64;
		for (k in 0...s.args.length)
			argTys[k + 1] = MirBuild.mty(s.args[k]);
		var res = rt == Void ? -1 : newVar(rt);
		var c = ic(o, fid);
		var join = joinBlock();
		var m1 = newBlock(), meth = newBlock(), notMeth = newBlock();
		// a method of the object's class with the call's signature
		var slot = load(I32, 4, c, Abi.IC_SLOT);
		br(cmp(CEq, slot, iconst(0)), m1, notMeth);
		seal(m1);
		cur = m1;
		br(cmp(CEq, load(I32, 4, c, Abi.IC_SIG), sigConst(s)), meth, notMeth);
		seal(meth);
		seal(notMeth);
		cur = meth;
		var r = callInd(load(I64, 8, c, Abi.IC_FN), VectorTools.cons(o, xs), rt, argTys);
		if (res >= 0) writeVar(res, cur, r);
		jmp(join);
		// a closure in a field
		cur = notMeth;
		var c1 = newBlock(), c2 = newBlock(), clos = newBlock(), slow = newBlock();
		slow.cold = true;
		br(cmp(CGt, slot, iconst(0)), c1, slow);
		seal(c1);
		cur = c1;
		br(cmp(CEq, load(I32, 1, c, Abi.IC_KIND), iconst("p".code)), c2, slow);
		seal(c2);
		cur = c2;
		var k = load(I64, 8, o, 0, false, op1(SExt, I64, op2(Sub, I32, slot, iconst(1))), 8);
		br(isSig(k, s), clos, slow);
		seal(clos);
		seal(slow);
		cur = clos;
		var r2 = callInd(load(I64, 8, k, 0), VectorTools.cons(k, xs), rt, argTys);
		if (res >= 0) writeVar(res, cur, r2);
		jmp(join);
		// the slow path: arguments packed in 8-byte words
		cur = slow;
		var n = xs.length == 0 ? 1 : xs.length;
		var area = frameSlot(8 * n, 8);
		var av = stackAddr(area);
		if (xs.length == 0) store(8, av, 0, lconst(0, 0));
		for (i in 0...xs.length)
			store(8, av, 8 * i, switch s.args[i] {
				case TF64: op1(FToBits, I64, xs[i]);
				case TI32 | TBool: op1(ZExt, I64, xs[i]);
				case _: xs[i];
			});
		var u = call("hx_anon_call_slow", vector(o, fid, sigConst(s), av), I64);
		if (res >= 0) writeVar(res, cur, switch s.ret {
			case TF64: op1(BitsToF, F64, u);
			case TI32 | TBool: op1(Trunc, I32, u);
			case _: u;
		});
		jmp(join);
		seal(join);
		cur = join;
		return res >= 0 ? readVar(res, cur) : -1;
	}

	// hx_is_sig(c, sig): a closure (TK_CLOSURE or TK_BOUND) of that signature
	function isSig(k:Int, s:SigInfo):Int {
		var r = newVar(I32);
		writeVar(r, cur, iconst(0));
		var nn = newBlock(), c2 = newBlock(), join = newBlock();
		br(cmp(CNe, k, lconst(0, 0)), nn, join);
		seal(nn);
		cur = nn;
		var ti = op1(ZExt, I64, tindex(k));
		var te = op2(Add, I64, symAddr("rt_types"), op2(Mul, I64, ti, lconst32(Abi.TYPE_SIZE)));
		var tk = load(I32, 1, te, 8);
		// TK_CLOSURE = 6, TK_BOUND = 7
		br(cmp(CULe, op2(Sub, I32, tk, iconst(6)), iconst(1)), c2, join);
		seal(c2);
		cur = c2;
		writeVar(r, cur, cmp(CEq, load(I32, 4, te, 12), sigConst(s)));
		jmp(join);
		seal(join);
		cur = join;
		return readVar(r, cur);
	}
}
