package hxmc;

import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// The machine-independent IR hxmc compiles its IR (hxmc.ir) to (MirBuild): a control
// flow graph of basic blocks in SSA form over three value types. Values are
// instructions, numbered by `id` in their function (MFunc.vals). Pointers
// are I64. Calls follow the C ABI of the target (lowered by the target's
// instruction selection).
enum abstract MTy(Int) to Int {
	var I32;
	var I64;
	var F64;
	var Void;
}

enum abstract Op(Int) to Int {
	// values
	var Param; // imm: argument index
	var Const; // imm (I32), imm/imm2 (I64: low/high)
	var ConstF; // f
	var SymAddr; // sym + imm
	var TlsLoad; // sym: a runtime thread-local variable (I64)
	var TlsStore; // sym, a
	var StackAddr; // imm: frame slot (MFunc.slots)
	var Copy; // a
	var Phi; // args, in the order of the block's preds
	var Add;
	var Sub;
	var Mul;
	var And;
	var Or;
	var Xor;
	var Shl; // count masked by the width (as x86-64 and arm64 do)
	var Sar;
	var Shr;
	var Neg;
	var Not;
	var Div; // signed, machine semantics (the builder excludes /0 and MIN/-1)
	var Rem;
	var FAdd;
	var FSub;
	var FMul;
	var FDiv;
	var FNeg;
	var FSqrt;
	var FAbs;
	var Cmp; // imm: Cond; a, b; the result is an I32 0/1
	var SExt; // I32 -> I64
	var ZExt; // I32 -> I64
	var Trunc; // I64 -> I32
	var I2F; // I32 or I64 (from a's type) -> F64
	var F2I; // F64 -> I32/I64, truncating (machine semantics out of range)
	var BitsToF; // I64 -> F64
	var FToBits; // F64 -> I64
	var Select; // a ? b : c (a: I32)
	var Load; // a: base, b: index (-1 none), imm: displacement, imm2: scale, size: bytes, signed
	var Store; // a: base, b: index, c: value, imm, imm2, size
	var Call; // sym (direct) or a (indirect); args; ty: result
	// terminators
	var Jmp; // targets[0]
	var Br; // a != 0 ? targets[0] : targets[1]
	var Switch; // a; cases (values) -> targets[i], targets[last]: default
	var Ret; // a (-1: none)
	var Unreachable; // after a call that does not return
	// values (late additions)
	var Rotr; // a rotated right by the constant b (I32/I64)
	// object-level operations (docs/plans/codegen.md, "Object-level Mir"):
	// MirBuild makes them, MemLower lowers them to the instructions above
	// (layouts, loads and stores, allocation, barriers, the shadow stack);
	// no back end sees them. Their static part is MIns.info (OInfo)
	var NullCheck; // a: a reference about to be dereferenced (explicit null tests only); info.key
	var New; // a new object (info: what, its allocation); args: the cold site's references (OInfo.cold)
	var NewDyn; // a: slots, b, c: the header's words (Mem.alloc of a run-time size); args as New
	var InitField; // a: a new object, b: the value of its field (info.t, loc, next)
	var GetField; // a: an object (info.t, loc)
	var SetField; // a: an object, b: the value (info.t, loc, flag: a null literal)
	var FieldAddr; // a: an object (info.loc): the address of a struct field's memory
	var EnumTag; // a: an enum value (info.en)
	var TypeTest; // a: a reference (info.cls): an instance of the class or a subclass
	var Box; // a: a scalar (info.t) as Dynamic
	var Unbox; // a: a Dynamic (info.t)
	var VirtualCall; // args: the receiver first (info.sel, sig)
	var ClosureCall; // args: the closure first (info.sig)
	var AnonGet; // a: an object (info.name, t, shape: the hint)
	var AnonTest; // a: an object, b: the field's id (info.name, t); targets: hit (the object has the field, of the kind), miss
	var AnonStore; // a: an object, b: the value, c: its AnonTest (in the hit block; info.t)
	var AnonCall; // a: an object; args: the arguments (info.name, sig)
	var ArrayLength; // a: an Array
	var ArrayGet; // a: an Array, b: the index (info.t, flag: checked)
	var ArraySet; // a: an Array, b: the index, c: the value (info.t, rootSlot, listIndex); args as New
	var ArrayPush; // a: an Array, c: the value; as ArraySet
	var NewArray; // an Array literal of info.n elements of info.t (ArrayInit stores them); args as New
	var ArrayInit; // a: a NewArray, b: an element's value (info.loc: its index)
	var NewNArray; // a: the length (info.kind); args as New
	var NArrayInit; // a: NativeArray storage just made (hx_narray_new_n), b: an element's value (info.loc: its index, kind)
	var NArrayLength; // a: NativeArray storage
	var NArrayGet; // a: storage, b: the index (info.n: the element's bytes)
	var NArraySet; // a: storage, b: the index, c: the value (info.n; info.flag: a reference)
	var NArrayDyn; // a: storage, b: the index, c: the value (-1: a read) of a NativeArray seen as Dynamic; args as New
	var RefStore; // a: an object, b: the offset of a reference in it, c: the value (Mem.setRefBarrier)
	// WasmGC's object-level Mir only (MFunc.gc: no memory lowering; wasmgc.MirGen
	// emits it, docs/plans/codegen.md, "Object-level Mir"):
	var IrNode; // an expression or a statement of the IR (info.ex, info.stmt) over the values args (its placeholder locals, info.ph)
	var VarGet; // a local kept out of SSA (a try function's: MFunc.vars; info.n: its index)
	var VarSet; // a: the value (info.n)
	var Try; // a try body entered: targets: the body's first block, the handler's (its first instruction: Catch)
	var Catch; // the exception caught (the handler's first instruction)
}

// the static part of an object-level operation (MIns.info): what it is about
class OInfo {
	public var t:hxmc.ir.Ir.Ty = hxmc.ir.Ir.Ty.TVoid; // the field's, element's or boxed value's type
	public var loc = 0; // a field's slot (an Int or Bool its 4-byte index: ClassInfo.locs); an element's index
	public var cls:Null<hxmc.ir.Ir.ClassInfo>;
	public var ctor:Null<hxmc.ir.Ir.CtorInfo>;
	public var lambda:Null<hxmc.ir.Ir.LambdaInfo>;
	public var shape:Null<hxmc.ir.Ir.ShapeInfo>;
	public var en:Null<hxmc.ir.Ir.EnumInfo>;
	public var sig:Null<hxmc.ir.Ir.SigInfo>;
	// AnonGet, AnonTest, AnonCall: the field's name; New: what it makes (NEW_*)
	public var name:Null<String>;

	public static inline var NEW_OBJECT = "object"; // a class instance (cls), its fields zero
	public static inline var NEW_ENUM = "enum"; // an enum value (ctor); InitField sets its parameters
	public static inline var NEW_CLOSURE = "closure"; // a closure (lambda); InitField sets its captures
	public static inline var NEW_BOX = "box"; // a captured variable's box (t); InitField sets it
	public static inline var NEW_ANON = "anon"; // an anonymous object (shape); InitField sets its fields
	public static inline var NEW_ARRAY = "array"; // an empty Array of elements t
	public static inline var NEW_RAW = "raw"; // Mem.alloc: an object of the runtime's own layout

	// New: its slots, type index, kind (Abi.K_OBJ...) and whether they must
	// read as zeros (else every one is written first); NewArray: its elements
	public var n = 0;
	public var tindex = -1;
	public var kind = 0;
	public var zero = false;
	public var flag = false;
	// New and InitField of an enum value: the 8-byte slot whose upper half
	// is cleared after them, before the next parameter is evaluated (an
	// Int's or Bool's: the storage is not zeroed; -1: none)
	public var next = -1;
	public var sel = -1; // VirtualCall: the selector
	public var key = -1; // NullCheck: the frame slot of the enclosing handler (-1: none)
	// a GC point at a cold site (SCold, hxmc.Roots): the references live
	// across its slow path (MIns.args, nspill of them) are stored on the
	// shadow stack there (spillBase: in the frame's slots from that one,
	// else pushed) and read back after it: in its continuation, the phi of
	// such a local (relocs: the local's index among them) gets a value per
	// edge from MemLower (MIns.imm: that index + 1)
	public var cold = false;
	public var nspill = 0;
	public var relocs:Null<Map<Int, Int>>;
	// the block the code after it is in, whose predecessors are its
	// lowering's last edges (MirBuild.obj: MemLower.branches)
	public var cont:Null<MBlock>;
	public var spillBase = -1;
	public var fr = false; // the frame's address (MirBuild's fr) follows the spills in args
	public var rootSlot = -1; // ArraySet, ArrayPush: the array local's shadow-stack slot (-1: spilled at listIndex)
	public var listIndex = -1;
	// a store with the write barrier: its last two arguments are the
	// nursery's start and size (Opt.operands, MemLower.setPtr)
	// Ir: the IR's expression or statement (one of them), its placeholders
	// (the locals that stand for the values args, in order)
	public var ex:Null<hxmc.ir.Ir.Ex>;
	public var stmt:Null<hxmc.ir.Ir.Stmt>;
	public var ph:Null<haxe.ds.Vector<hxmc.ir.Ir.Local>>;
	public var young = false;
	// SetField of a reference into an object allocated since the last point
	// where a collection may happen: no write barrier (Opt.freshTargets)
	public var fresh = false;
	// ArrayGet, ArraySet, ArrayPush: where the array's header and the index
	// widened start among the arguments (Opt.operands; -1: none)
	public var ops = -1;

	public function new() {}

	// a copy (the inliner's: its continuation the copy's)
	public function copy(cont:Null<MBlock>):OInfo {
		var o = new OInfo();
		o.t = t;
		o.loc = loc;
		o.cls = cls;
		o.ctor = ctor;
		o.lambda = lambda;
		o.shape = shape;
		o.en = en;
		o.sig = sig;
		o.name = name;
		o.n = n;
		o.tindex = tindex;
		o.kind = kind;
		o.zero = zero;
		o.flag = flag;
		o.next = next;
		o.sel = sel;
		o.key = key;
		o.cold = cold;
		o.nspill = nspill;
		o.relocs = relocs;
		o.cont = cont;
		o.spillBase = spillBase;
		o.fr = fr;
		o.rootSlot = rootSlot;
		o.listIndex = listIndex;
		o.ex = ex;
		o.stmt = stmt;
		o.ph = ph;
		o.young = young;
		o.fresh = fresh;
		o.ops = ops;
		return o;
	}
}

enum abstract Cond(Int) to Int from Int {
	var CEq;
	var CNe;
	var CLt;
	var CLe;
	var CGt;
	var CGe;
	var CULt;
	var CULe;
	var CUGt;
	var CUGe;
	// doubles (C semantics: an ordered comparison is false with NaN, != true)
	var FEq;
	var FNe;
	var FLt;
	var FLe;
	var FGt;
	var FGe;
}

class MIns {
	public var op:Op;
	public var ty:MTy;
	// the Haxe-level type of the value, carried from the IR (MirBuild: a
	// class instance, an array and its element kind, a closure's signature,
	// an enum or one of its constructors, Dynamic, a struct value, a plain
	// scalar); null: a machine value without one (an address, a header word,
	// what a lowering computes). Object-level passes read it (docs/plans/codegen.md,
	// "Object-level Mir"); the back ends never do
	public var vty:Null<hxmc.ir.Ir.Ty>;
	public var info:Null<OInfo>; // an object-level operation's static part
	public var id:Int = -1; // value number (every instruction gets one)
	public var a:Int = -1;
	public var b:Int = -1;
	public var c:Int = -1;
	public var imm:Int = 0;
	public var imm2:Int = 0;
	public var f:Float = 0;
	public var size:Int = 0;
	public var signed:Bool = false;
	public var sym:Null<String>;
	// (the lists below are empty where they do not apply: the shared empty vector)
	public var args:Vector<Int> = vector(); // Call, Phi
	public var targets:Vector<MBlock> = vector(); // terminators
	public var cases:Vector<Int> = vector(); // Switch
	public var block:MBlock;
	public var noReturn = false; // Call
	public var returnsTwice = false; // Call (setjmp)
	public var keepsFrame = false; // Call: nothing collects meanwhile (Opt: the frame's shadow-stack slots keep their values)
	public var variadic = -1; // Call: the first variadic argument of a C function (-1: none)
	public var argTys:Vector<MTy> = vector(); // Call: the C types of the arguments (I32 stays 32-bit in the ABI)
	// Call of a C function (MirBuild.cCall), not of the runtime or a Haxe function
	// by its symbol: what cSizes being set said before it was a Vector, empty for
	// a C function without arguments too
	public var cCall = false;
	// Call of a C function: the size of each argument in C (1, 2, 4 or 8; float: 4),
	// for Apple arm64's stack arguments, packed by size (empty: 4 for I32, else 8)
	public var cSizes:Vector<Int> = vector();
	// Call of a C function taking structs by value (MirBuild.cStructArg): per
	// argument, the number of registers of the struct whose first part it is
	// (its parts all go in registers or all on the stack; negative: on the
	// stack always, System V's MEMORY class), 0 for the others (empty: no
	// struct argument, 1 for each)
	public var cGroups:Vector<Int> = vector();
	// Call of a C function returning a struct (MirBuild.cStructRet, CAbi):
	// the last argument is the address its value is stored at, not passed
	// (except as x8 on arm64 when cRet is empty); cRet: the parts of the
	// result in registers (integer ones in the integer result registers in
	// order, float ones in the float result registers)
	public var structRet = false;
	public var cRet:Vector<CAbi.CPart> = vector();
	public var dead = false;
	public var mem = 0; // Load/Store: the memory class (Opt.MOther...)
	// Store of a reference into the heap or a static (MemLower.setPtr): it
	// publishes what it stores, so the thread's stores before it (the
	// initialising stores of the object) are seen first by a thread that
	// reads the reference (arm64: dmb ishst before it; x86-64 orders stores)
	public var release = false;
	public var pos = 0; // (-debug) the source position (SrcPos; 0: none)

	public function new(op, ty) {
		this.op = op;
		this.ty = ty;
	}

	public inline function isTerm():Bool
		return op == Jmp || op == Br || op == Switch || op == Ret || op == Unreachable || op == AnonTest || op == Try;

	// an object-level operation (lowered by MemLower)
	public inline function isObj():Bool
		return (op : Int) >= (NullCheck : Int);

	// Phi: the argument of the k-th pred dropped (its edge removed; the
	// arguments are reallocated, as edges change rarely; none when there is no
	// such argument yet)
	public function removeArg(k:Int) {
		var n = args.length;
		if (k >= n) return;
		var a = new Vector<Int>(n - 1);
		Vector.blit(args, 0, a, 0, k);
		Vector.blit(args, k + 1, a, k, n - k - 1);
		args = a;
	}

	// Phi: an argument added (for a new pred, last)
	public function addArg(v:Int) {
		var n = args.length;
		var a = new Vector<Int>(n + 1);
		Vector.blit(args, 0, a, 0, n);
		a[n] = v;
		args = a;
	}
}

class MBlock {
	public var id:Int;
	public var ins:Array<MIns> = []; // phis first, the terminator last
	public var preds:Array<MBlock> = [];
	public var succs:Array<MBlock> = [];
	public var sealed = false;
	public var filled = false;
	public var cold = false; // a slow path: laid out at the end of the function
	public var order = -1; // position in the layout
	public var handler = false; // reached by a second return of setjmp
	public var mark = 0; // a pass's visit mark (MFunc.newMark)
	public var tmp = 0; // a pass's number for the block (valid where marked)

	public function new(id)
		this.id = id;

	public inline function term():Null<MIns>
		return ins.length > 0 && ins[ins.length - 1].isTerm() ? ins[ins.length - 1] : null;
}

class MFunc {
	public var name:String;
	public var params:Vector<MTy> = vector();
	public var ret:MTy = Void;
	public var blocks:Array<MBlock> = [];
	public var vals:Array<MIns> = [];
	public var slots:Array<{size:Int, align:Int}> = []; // frame slots (StackAddr)
	public var blocksHere = false; // FuncInfo.blocksHere (Inline: its calls never keep the frame)
	public var allocs = 0; // objects allocated inline and boxes made, at most (Escape: none, nothing to do)
	// object-level Mir for WasmGC (MirBuild.gc): never lowered to memory; the
	// locals kept out of SSA (VarGet, VarSet), by index: their types
	public var gc = false;
	public var vars:Array<hxmc.ir.Ir.Ty> = [];
	// entered from C with structs by value (MirBuild.cEntry): the parameters'
	// groups (MIns.cGroups) and C sizes (MIns.cSizes); a Param of index -1
	// is x8 on arm64 (the address of a struct result); empty: not entered from C
	public var cParams:Vector<Int> = vector();
	public var cParamSizes:Vector<Int> = vector();
	// returning a struct in registers (structRet): Ret's value is its address,
	// cRet its parts (MIns.cRet)
	public var structRet = false;
	public var cRet:Vector<CAbi.CPart> = vector();
	public var entry:MBlock;
	var marks = 0;
	var cfgOf:Null<Cfg<MBlock>>;

	public function new(name)
		this.name = name;

	// a fresh mark: the blocks a pass sets MBlock.mark to it are visited
	public inline function newMark():Int
		return ++marks;

	// vectors of n numbers (new Vector zeroes them on hxmc)
	public static function ints(n:Int, v:Int):haxe.ds.Vector<Int> {
		var a = new haxe.ds.Vector<Int>(n);
		if (v != 0) a.fill(v);
		return a;
	}

	public static function iota(n:Int):haxe.ds.Vector<Int> {
		var a = new haxe.ds.Vector<Int>(n);
		for (i in 0...n)
			a[i] = i;
		return a;
	}

	// the control-flow analyses (Cfg), kept until the graph changes: a pass
	// that changes edges (the blocks' succs or preds) calls edited
	public function cfg():Cfg<MBlock> {
		if (cfgOf == null) {
			var ids = 0;
			for (b in blocks)
				if (b.id >= ids) ids = b.id + 1;
			cfgOf = new Cfg<MBlock>(entry, ids);
		}
		return cfgOf;
	}

	public inline function edited()
		cfgOf = null;

	public function newBlock():MBlock {
		var b = new MBlock(blocks.length);
		blocks.push(b);
		return b;
	}

	public function slot(size:Int, align:Int):Int {
		slots.push({size: size, align: align});
		return slots.length - 1;
	}

	public function dump():String {
		var s = new StringBuf();
		s.add('func $name(${params.join(", ")}) -> $ret\n');
		for (b in blocks) {
			s.add('b${b.id}: preds ${[for (p in b.preds) "b" + p.id].join(",")}${b.cold ? " cold" : ""}${b.handler ? " handler" : ""}\n');
			for (i in b.ins)
				if (!i.dead) s.add("  " + insString(i) + "\n");
		}
		return s.toString();
	}

	public static function insString(i:MIns):String {
		var s = (i.ty != Void ? 'v${i.id}:${tyName(i.ty)}${i.vty != null ? "<" + vtyName(i.vty) + ">" : ""} = ' : '') + opName(i.op);
		var parts = [];
		if (i.op == Const) parts.push(Std.string(i.imm) + (i.ty == I64 && i.imm2 != (i.imm < 0 ? -1 : 0) ? ' hi ${i.imm2}' : ""));
		if (i.op == ConstF) parts.push(Std.string(i.f));
		if (i.op == Cmp) parts.push(condName(i.imm));
		if (i.sym != null) parts.push(i.sym + (i.imm != 0 && i.op == SymAddr ? '+${i.imm}' : ""));
		for (x in [i.a, i.b, i.c])
			if (x >= 0) parts.push('v$x');
		if (i.op == Load || i.op == Store) parts.push('disp ${i.imm} scale ${i.imm2} size ${i.size}${i.signed ? " s" : ""}');
		if (i.op == Param || i.op == StackAddr) parts.push(Std.string(i.imm));
		var o = i.info;
		if (o != null) {
			if (o.cls != null) parts.push(o.cls.name);
			if (o.ctor != null) parts.push(o.ctor.en.name + "." + o.ctor.name);
			if (o.lambda != null) parts.push("lambda" + o.lambda.id);
			if (o.name != null) parts.push(o.name);
			if (!o.t.match(TVoid)) parts.push(vtyName(o.t) + " at " + o.loc);
			if (o.cold) parts.push('cold ${o.nspill}');
		}
		if (i.op == Call || i.op == Phi || i.args.length > 0) parts.push("(" + [for (x in i.args) 'v$x'].join(", ") + ")");
		if (i.op == Switch || i.cases.length > 0) parts.push("[" + i.cases.join(",") + "]");
		if (i.targets.length > 0) parts.push("-> " + [for (t in i.targets) 'b${t.id}'].join(", "));
		return s + " " + parts.join(" ");
	}

	public static function tyName(t:MTy):String
		return switch t {
			case I32: "i32";
			case I64: "i64";
			case F64: "f64";
			case Void: "void";
		};

	// a Haxe-level type, short (dumps)
	public static function vtyName(t:hxmc.ir.Ir.Ty):String
		return switch t {
			case TRef(r):
				switch r {
					case RObj(c): c.name;
					case REnum(e): e == null ? "EnumValue" : e.name;
					case RCtor(c): c.en.name + "." + c.name;
					case RArr(t): "Array<" + vtyName(t) + ">";
					case RNativeArr(t): "NativeArray<" + vtyName(t) + ">";
					case RClos(s): "fn " + s.key;
					case RBox(t): "box " + vtyName(t);
					case RNull(t): "Null<" + vtyName(t) + ">";
					case RStr: "String";
					case RAnon: "anon";
					case RAny: "Dynamic";
					case RType: "type";
					case RNative(p): p;
				}
			case TStruct(n, _): "struct " + n;
			case _: hxmc.ir.Ir.repr(t);
		};

	static final CONDS:Vector<String> = vector("eq", "ne", "lt", "le", "gt", "ge", "ult", "ule", "ugt", "uge", "feq", "fne", "flt", "fle", "fgt", "fge");

	public static function condName(c:Int):String
		return CONDS[c];

	static final OPS:Vector<String> = vector("param", "const", "constf", "symaddr", "tlsload", "tlsstore", "stackaddr", "copy", "phi", "add", "sub", "mul", "and",
		"or", "xor", "shl", "sar", "shr", "neg", "not", "div", "rem", "fadd", "fsub", "fmul", "fdiv", "fneg", "fsqrt", "fabs", "cmp", "sext", "zext", "trunc",
		"i2f", "f2i", "bitstof", "ftobits", "select", "load", "store", "call", "jmp", "br", "switch", "ret", "unreachable", "rotr", "nullcheck", "new",
		"newdyn", "initfield", "getfield", "setfield", "fieldaddr", "enumtag", "typetest", "box", "unbox", "virtualcall", "closurecall", "anonget", "anontest",
		"anonstore", "anoncall", "arraylength", "arrayget", "arrayset", "arraypush", "newarray", "arrayinit", "newnarray", "narrayinit", "narraylength",
		"narrayget", "narrayset", "narraydyn", "refstore", "irnode", "varget", "varset", "try", "catch");

	public static function opName(o:Op):String
		return OPS[(o : Int)];
}

// The source positions of instructions (-debug: MIns.pos, LIns.pos): a file
// and a line as one number, the same for the whole run (0: none). Positions
// only describe the code: no pass looks at them.
class SrcPos {
	static var lock = new sys.thread.Mutex();
	static var ids = new Map<String, Int>();
	static var files:Array<String> = [""];
	static var lines:Array<Int> = [0];

	public static function id(file:String, line:Int):Int {
		var k = line + ":" + file;
		lock.acquire();
		var v = ids.get(k);
		if (v == null) {
			v = files.length;
			files.push(file);
			lines.push(line);
			ids.set(k, v);
		}
		lock.release();
		return v;
	}

	public static function get(p:Int):{file:String, line:Int} {
		lock.acquire();
		var r = {file: files[p], line: lines[p]};
		lock.release();
		return r;
	}
}
