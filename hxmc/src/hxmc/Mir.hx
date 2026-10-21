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
	public var pos = 0; // (-debug) the source position (SrcPos; 0: none)

	public function new(op, ty) {
		this.op = op;
		this.ty = ty;
	}

	public inline function isTerm():Bool
		return op == Jmp || op == Br || op == Switch || op == Ret || op == Unreachable;

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
	public var loopDepth = 0;
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
		var s = (i.ty != Void ? 'v${i.id}:${tyName(i.ty)} = ' : '') + opName(i.op);
		var parts = [];
		if (i.op == Const) parts.push(Std.string(i.imm) + (i.ty == I64 && i.imm2 != (i.imm < 0 ? -1 : 0) ? ' hi ${i.imm2}' : ""));
		if (i.op == ConstF) parts.push(Std.string(i.f));
		if (i.op == Cmp) parts.push(condName(i.imm));
		if (i.sym != null) parts.push(i.sym + (i.imm != 0 && i.op == SymAddr ? '+${i.imm}' : ""));
		for (x in [i.a, i.b, i.c])
			if (x >= 0) parts.push('v$x');
		if (i.op == Load || i.op == Store) parts.push('disp ${i.imm} scale ${i.imm2} size ${i.size}${i.signed ? " s" : ""}');
		if (i.op == Param || i.op == StackAddr) parts.push(Std.string(i.imm));
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

	static final CONDS:Vector<String> = vector("eq", "ne", "lt", "le", "gt", "ge", "ult", "ule", "ugt", "uge", "feq", "fne", "flt", "fle", "fgt", "fge");

	public static function condName(c:Int):String
		return CONDS[c];

	static final OPS:Vector<String> = vector("param", "const", "constf", "symaddr", "tlsload", "tlsstore", "stackaddr", "copy", "phi", "add", "sub", "mul", "and",
		"or", "xor", "shl", "sar", "shr", "neg", "not", "div", "rem", "fadd", "fsub", "fmul", "fdiv", "fneg", "fsqrt", "fabs", "cmp", "sext", "zext", "trunc",
		"i2f", "f2i", "bitstof", "ftobits", "select", "load", "store", "call", "jmp", "br", "switch", "ret", "unreachable", "rotr");

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
