package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The operations of the interpreter's code (hxmc/src/hxmc/interp/InterpGen.hx
// writes them: the same list). Operands are words after the operation: d
// the register written, a, b, c registers read, t a branch target (a byte
// offset from the start of its operation).
enum abstract IOp(Int) from Int to Int {
	var TLSLD = 0; // d t
	var TLSST; // a t
	var TLSST_HCUR; // a prevOff: a try's handler set or popped
	var SADDR; // d off: a frame slot's address
	var MOV; // d a
	var ADD; // d a b (64 bits; an I32's upper half is never read)
	var SUB;
	var MUL;
	var AND;
	var OR;
	var XOR;
	var NEG; // d a
	var NOT;
	var SHL32; // d a b
	var SHL64;
	var SAR32;
	var SAR64;
	var SHR32;
	var SHR64;
	var DIV32;
	var DIV64;
	var REM32;
	var REM64;
	var ROTR32;
	var ROTR64;
	var FADD;
	var FSUB;
	var FMUL;
	var FDIV;
	var FNEG; // d a
	var FSQRT;
	var FABS;
	var EQ32; // d a b: Mir's conditions, in its order
	var NE32;
	var LT32;
	var LE32;
	var GT32;
	var GE32;
	var ULT32;
	var ULE32;
	var UGT32;
	var UGE32;
	var EQ64;
	var NE64;
	var LT64;
	var LE64;
	var GT64;
	var GE64;
	var ULT64;
	var ULE64;
	var UGT64;
	var UGE64;
	var FEQ;
	var FNE;
	var FLT;
	var FLE;
	var FGT;
	var FGE;
	var SEXT; // d a
	var ZEXT;
	var TRUNC;
	var I2F32;
	var I2F64;
	var F2I32;
	var F2I64;
	var SELECT; // d a b c
	var LD1S; // d base disp
	var LD1U;
	var LD2S;
	var LD2U;
	var LD4S;
	var LD4U;
	var LD8;
	var LDF4;
	var LDX1S; // d base index scale disp
	var LDX1U;
	var LDX2S;
	var LDX2U;
	var LDX4S;
	var LDX4U;
	var LDX8;
	var LDXF4;
	var ST1; // base disp v
	var ST2;
	var ST4;
	var ST8;
	var STF4;
	var STX1; // base index scale disp v
	var STX2;
	var STX4;
	var STX8;
	var STXF4;
	var CALLN; // k d n args: the call-out stub of symbol table entry k (d -1: no result)
	var CALLNI; // k f d n c args: the call-out stub k calling the code at f, entries c and c + 1 its inline cache
	var CALLI; // k d n args: the interpreted function whose descriptor is entry k
	var SETJMP; // d h: a try's setjmp on the handler h
	var JMP; // t
	var MOVJ1; // d s t: a phi's move, then the jump
	var MOVJ2; // d s d s t
	var MOVJN; // n (d s)*n t
	var BR; // a t1 t2
	var BEQ32; // a b t1 t2: a compare and its branch, the conditions as above
	var BNE32;
	var BLT32;
	var BLE32;
	var BGT32;
	var BGE32;
	var BULT32;
	var BULE32;
	var BUGT32;
	var BUGE32;
	var BEQ64;
	var BNE64;
	var BLT64;
	var BLE64;
	var BGT64;
	var BGE64;
	var BULT64;
	var BULE64;
	var BUGT64;
	var BUGE64;
	var BFEQ;
	var BFNE;
	var BFLT;
	var BFLE;
	var BFGT;
	var BFGE;
	var SWITCH; // a n (v t)*n t
	var SWITCHT; // a lo n t*n t: a table on a - lo
	var RET; // a
	var RETV;
	var UNREACH;
	var TLSXLD; // d k: thread-local variable k of code loaded at run time (a block per thread)
	var TLSXST; // a k
	// (code loaded at run time into a Mir host, Mem.mirHost: hxmc.interp.InterpAbi's register image)
	var CALLX; // f d len n args rk nst dst*n [a np (w off size)*np]: native code at register f (the shape after the arguments: callX)
	var CALLXI; // f d len c n args shape: an indirect call, entries c and c + 1 its inline cache (an interpreted function: run here)
	var SPECIAL; // k d a b c: an expansion of the instruction selections (hxmc$*: atomics, float32 conversions; SP_*)
	var FENCE; // a store's release (arm64)
	var LAZY; // k: a function not compiled yet (its descriptor a stub): compiled, then called (lazy)
	var UDIV64; // d a b: unsigned (Mem.udiv)
	var UREM64;
}

// An interpreter of hxmc's Mir inside the running program (-D hxmc.interp):
// the functions the tool interprets are their Mir after its optimizations,
// encoded as words (a descriptor per function, InterpGen), run here with
// the program's memory, layouts and runtime; only their instructions are
// executed by this loop rather than by the CPU. Native code reaches an
// interpreted function through its entry stub (a native function of its
// symbol: its arguments into a buffer, then hxmc_interp_enter); an
// interpreted function calls native code through call-out stubs (one per
// callee and signature: the arguments from a buffer, the call as the tool
// compiles it, the result into the buffer), so every ABI detail stays the
// code generator's. An indirect call whose target is an entry stub runs its
// function directly (lookup, cached per call site). Code loaded at run time
// into a Mir host (a compiler with Mir macros, macro.Loader) has neither: it
// calls native code through the register image (CALLX, CALLXI: the
// compiler's call-outs) and native code calls it through an entry of the
// compiler's pools (poolEntry, poolEnter; hxmc/src/hxmc/interp/InterpAbi.hx).
//
// Registers (8 bytes each: the function's constants first, copied when its
// frame starts, then its values) and frame slots are on a stack of this
// thread's (isp), never in the collector's heap: the interpreter allocates
// nothing a collection could move, and the code it runs keeps its
// references across GC points in the shadow stack as native code does.
//
// A try's setjmp: the interpreted code links its handler h (rt_hcur) and
// calls setjmp(h); enterTry runs the rest of the frame inside a native try,
// whose handler is linked above h, so a throw (rt_throw: longjmp to the
// innermost handler) lands there, and the frame goes on at the setjmp with
// 1. When the interpreted code unlinks h (its try ended: rt_hcur set to h's
// previous handler) the native try is left: exec returns the level popped
// to the enterTry of that level.
@:access(hxmc.rt.Gc)
@:access(hxmc.rt.Threads)
class Interp {
	// a descriptor (InterpGen): magic, registers, frame bytes, code words,
	// constants, parameters, flags (D_*), then the offsets from the
	// descriptor (64 bits) of its code, symbol table, constants and
	// parameters' sources (an entry's: their byte offsets in the register
	// image); the code from HEADER. Registers: the constants, the
	// parameters, the values. A stub's header (LAZY) becomes its function's
	// once it is compiled: whatever holds the descriptor calls the function
	static inline var HEADER = 64;
	static inline var H_NREGS = 4;
	static inline var H_FRAME = 8;
	static inline var H_NCONSTS = 16;
	static inline var H_NPARAMS = 20;
	static inline var H_CODE = 32;
	static inline var H_SYMS = 40;
	static inline var H_CONSTS = 48;
	static inline var H_SOURCES = 56;
	static inline var D_FLOAT = 1; // it returns a double
	static inline var D_STACK = 2; // its arguments take stack words
	static inline var D_NOENTRY = 4; // more than the image's stack words
	static inline var MAGIC = 0x32495848; // "HXI2"
	// a frame (on the interpreter's stack): its code, symbol table,
	// registers, slots, where its result goes, end, where it goes on (a try ended), the
	// tries entered, their handlers
	static inline var F_CODE = 0;
	static inline var F_SYMS = 8;
	static inline var F_REGS = 16;
	static inline var F_SLOTS = 24;
	static inline var F_RES = 32;
	static inline var F_TOP = 40;
	static inline var F_IP = 48;
	static inline var F_NTRIES = 56;
	static inline var F_TRIES = 64;
	static inline var MAX_TRIES = 16;
	static inline var FRAME = 192;
	// exec's results: the function returned, a try ended (enterTry goes on),
	// or the level of the try popped
	static inline var RETURNED = -1;
	static inline var CONTINUE = -2;
	// the runtime's thread-local variables (InterpGen.TLS)
	static inline var T_SP = 0;
	static inline var T_SP_HW = 1;
	static inline var T_HCUR = 2;
	static inline var T_EXN = 3;
	static inline var T_YPTR = 4;
	static inline var T_YLIM = 5;
	static inline var T_YRLIM = 6;
	static inline var T_MUT = 7;
	static inline var STACK_BYTES = 16 << 20;
	static inline var MIN32 = 0x80000000;

	@:hxmc.threadLocal("rt_interp_sp") static var isp:Ptr;
	@:hxmc.threadLocal("rt_interp_end") static var iend:Ptr;
	// the thread-local variables of code loaded at run time (TLSXLD: 4096 words, made at the first use)
	@:hxmc.threadLocal("rt_interp_tls") static var itls:Ptr;

	static function tlsBlock():Ptr {
		if (itls.isNull()) {
			var n:I64 = 8 * 4096;
			itls = LibC.malloc(n);
			LibC.memset(itls, 0, n);
		}
		return itls;
	}
	// the functions interpreted, by entry stub: (stub, descriptor) pairs,
	// open addressing (InterpGen.TABLE, then those registered by code loaded
	// at run time: made at the first entry or registration, on the main
	// thread, read only after)
	static var table:Ptr;
	static var mask:Int;
	static var count = 0;

	static function initStack() {
		var n:I64 = STACK_BYTES;
		var p = LibC.malloc(n);
		if (p.isNull()) throw "hxmc interp: no memory for the interpreter's stack";
		isp = p;
		// (a frame's check is made once its arguments are written: room for them)
		iend = p.addL(n - (1 << 20));
		if (table.isNull()) initTable();
	}

	static inline function hash(x:I64):Int
		return ((x >>> 4).toInt() * 0x9E3779B1) >>> 8;

	static function initTable() {
		var t = Mem.sym("hxmc_interp_fns");
		var n = Mem.getI64(t, 0).toInt();
		grow(2 * n);
		for (k in 0...n)
			insert(Mem.getI64(t, 8 + 16 * k), Mem.getI64(t, 16 + 16 * k));
	}

	// (the table with room for n entries, the ones it has moved over)
	static function grow(n:Int) {
		var size = 16;
		while (size < 2 * n)
			size <<= 1;
		var bytes:I64 = 16 * size;
		var tab = LibC.malloc(bytes);
		LibC.memset(tab, 0, bytes);
		var old = table, oldSize = table.isNull() ? 0 : mask + 1;
		table = tab;
		mask = size - 1;
		count = 0;
		for (k in 0...oldSize) {
			var key = Mem.getI64(old, k << 4);
			if (key != (0 : I64)) insert(key, Mem.getI64(old, (k << 4) + 8));
		}
		if (!old.isNull()) LibC.free(old);
	}

	static function insert(key:I64, desc:I64) {
		var h = hash(key) & mask;
		while (Mem.getI64(table, h << 4) != (0 : I64))
			h = (h + 1) & mask;
		Mem.setI64(table, h << 4, key);
		Mem.setI64(table, (h << 4) + 8, desc);
		count++;
	}

	// a function interpreted that code loaded at run time defines: its entry stub and descriptor
	public static function register(stub:Ptr, desc:Ptr) {
		if (table.isNull()) initTable();
		if (2 * (count + 1) > mask + 1) grow(2 * (count + 1));
		insert(stub.toI64(), desc.toI64());
	}

	// the entry of the function interpreted whose entry stub is at fn (its descriptor at +8), or null
	static function lookup(fn:I64):Ptr {
		var h = hash(fn) & mask;
		while (true) {
			var k = Mem.getI64(table, h << 4);
			if (k == fn) return table.add(h << 4);
			if (k == (0 : I64)) return Ptr.nil();
			h = (h + 1) & mask;
		}
	}

	// native code calling an interpreted function (its entry stub): the
	// arguments are 8-byte words at args, the result is written at args
	@:hxmc.export("hxmc_interp_enter") static function enter(desc:Ptr, args:Ptr):Void {
		if (isp.isNull()) initStack();
		var base = isp;
		try {
			var regs = base.add(FRAME), nc = Mem.getI32(desc, H_NCONSTS);
			for (k in 0...Mem.getI32(desc, H_NPARAMS))
				Mem.setI64At(regs, 0, nc + k, Mem.getI64At(args, 0, k));
			run(desc, args);
		} catch (e:Dynamic) {
			// (a native handler catches: this entry's frames are given back)
			isp = base;
			throw e;
		}
	}

	// a frame of the function at isp (its arguments written in its registers), run; its result written at res
	static function run(desc:Ptr, res:Ptr) {
		var nregs = Mem.getI32(desc, H_NREGS);
		var fr = isp;
		var regs = fr.add(FRAME);
		var slots = regs.add((nregs * 8 + 15) & ~15);
		var top = slots.add(Mem.getI32(desc, H_FRAME));
		if (!top.ult(iend)) throw "hxmc interp: stack overflow";
		isp = top;
		var code = desc.addL(Mem.getI64(desc, H_CODE));
		Mem.setPtr(fr, F_CODE, code);
		Mem.setPtr(fr, F_SYMS, desc.addL(Mem.getI64(desc, H_SYMS)));
		Mem.setPtr(fr, F_REGS, regs);
		Mem.setPtr(fr, F_SLOTS, slots);
		Mem.setPtr(fr, F_RES, res);
		Mem.setPtr(fr, F_TOP, top);
		Mem.setI32(fr, F_NTRIES, 0);
		// the constants
		var consts = desc.addL(Mem.getI64(desc, H_CONSTS));
		for (k in 0...Mem.getI32(desc, H_NCONSTS))
			Mem.setI64At(regs, 0, k, Mem.getI64At(consts, 0, k));
		exec(fr, code);
		isp = fr;
	}

	// compiles the function of stub desc (LAZY's k), whose arguments are
	// regs' first words (references among them kept across the collections
	// compiling makes), and makes desc's header the function's (code loaded
	// at run time: interp.MirMacros)
	public static var lazyHook:Null<(k:Int, desc:Ptr, regs:Ptr) -> Void> = null;

	// whether desc is a stub still (LAZY at its code's start, after its header)
	public static function isStub(desc:Ptr):Bool
		return Mem.getI64(desc, H_CODE) == (HEADER : I64) && Mem.getI32(desc, HEADER) == LAZY;

	// stub's header made the one of desc, its function compiled (its parts'
	// offsets from the stub): what calls the stub calls the function
	public static function become(stub:Ptr, desc:Ptr) {
		for (o in [H_NREGS, H_FRAME, 12, H_NCONSTS])
			Mem.setI32(stub, o, Mem.getI32(desc, o));
		for (o in [H_CODE, H_SYMS, H_CONSTS, H_SOURCES])
			Mem.setI64(stub, o, desc.toI64() + Mem.getI64(desc, o) - stub.toI64());
	}

	// a stub's frame (LAZY at its code's start, after its header): its
	// function compiled, then run in this frame, its arguments moved after
	// its constants
	static function lazy(fr:Ptr, ip:Ptr):Int {
		var desc = ip.add(-HEADER);
		var regs = Mem.getPtr(fr, F_REGS), res = Mem.getPtr(fr, F_RES);
		var n = Mem.getI32(desc, H_NPARAMS);
		if (lazyHook == null) throw "hxmc interp: a function not compiled, and no compiler";
		lazyHook(o(ip, 1), desc, regs);
		var nc = Mem.getI32(desc, H_NCONSTS);
		var k = n;
		while (k-- > 0)
			Mem.setI64At(regs, 0, nc + k, Mem.getI64At(regs, 0, k));
		isp = fr;
		run(desc, res);
		return RETURNED;
	}

	// the frame's try at the setjmp (level: the tries entered before), the
	// frame going on after it at ip
	// an exception the interpreted code's handlers let through (the compiler's own
	// from its macro API, as Eval's OCaml exceptions: interp.MirMacros)
	public static var uncatchable:Dynamic = null;
	// a handler's previous one's offset (the target's: the operand of TLSST_HCUR,
	// which links every try's handler before its enterTry)
	static var hprevOff = 0;

	static function enterTry(fr:Ptr, ip:Ptr, d:Int, h:Ptr):Int {
		var level = Mem.getI32(fr, F_NTRIES);
		if (level == MAX_TRIES) throw "hxmc interp: tries nested too deep";
		Mem.setPtr(fr, F_TRIES + 8 * level, h);
		Mem.setI32(fr, F_NTRIES, level + 1);
		var regs = Mem.getPtr(fr, F_REGS);
		var st = RETURNED;
		var caught = false;
		var hc = Ptr.nil();
		try {
			Mem.setI64At(regs, 0, d, 0);
			st = exec(fr, ip);
			hc = Gc.hcur;
		} catch (e:Dynamic) {
			caught = true;
			// (deeper frames were left by the longjmp: given back; the handler
			// the interpreted code reads its exception from)
			isp = Mem.getPtr(fr, F_TOP);
			Mem.setI32(fr, F_NTRIES, level);
			if (uncatchable != null && Mem.addr(e) == Mem.addr(uncatchable)) {
				// (on past this try: its handler h unlinked, as the interpreted code would)
				Gc.hcur = Mem.getPtr(h, hprevOff);
				throw e;
			}
			Gc.exn = Mem.addr(e);
		}
		if (caught) {
			Mem.setI64At(regs, 0, d, 1);
			st = exec(fr, ip);
			return st == level ? CONTINUE : st;
		}
		// (leaving the native try relinked its handler's previous one, h: as the interpreted code left it)
		Gc.hcur = hc;
		return st == level ? CONTINUE : st;
	}

	// operand k of the operation at ip
	static inline function o(ip:Ptr, k:Int):Int
		return Mem.getI32(ip, k << 2);

	static inline function gl(regs:Ptr, r:Int):I64
		return Mem.getI64At(regs, 0, r);

	static inline function sl(regs:Ptr, r:Int, v:I64)
		Mem.setI64At(regs, 0, r, v);

	static inline function gi(regs:Ptr, r:Int):Int
		return Mem.getI64At(regs, 0, r).toInt();

	static inline function si(regs:Ptr, r:Int, v:Int)
		Mem.setI64At(regs, 0, r, v);

	static inline function gf(regs:Ptr, r:Int):Float
		return Mem.getF64At(regs, 0, r);

	static inline function sf(regs:Ptr, r:Int, v:Float)
		Mem.setF64At(regs, 0, r, v);

	static inline function zext(v:Int):I64
		return ((v : I64) << 32) >>> 32;

	// n / d, unsigned (the Haxe of this runtime has no unsigned division: the
	// committed stage0 compiles it)
	static function udiv(n:I64, d:I64):I64 {
		if (d < 0) return Mem.ult(n, d) ? 0 : 1;
		if (n >= 0) return n / d;
		var q = ((n >>> 1) / d) << 1;
		if (!Mem.ult(n - q * d, d)) q += 1;
		return q;
	}

	static inline function b2i(b:Bool):Int
		return b ? 1 : 0;

	// the address of a load or store: register k, plus register k + 1 times k + 2
	static inline function base(regs:Ptr, ip:Ptr, k:Int):Ptr
		return Ptr.ofI64(gl(regs, o(ip, k)));

	static inline function indexed(regs:Ptr, ip:Ptr, k:Int):Ptr
		return Ptr.ofI64(gl(regs, o(ip, k)) + gl(regs, o(ip, k + 1)) * o(ip, k + 2));

	static function tlsGet(t:Int):I64
		return switch t {
			case T_SP: Gc.sp.toI64();
			case T_SP_HW: Gc.hw.toI64();
			case T_HCUR: Gc.hcur.toI64();
			case T_EXN: Gc.exn.toI64();
			case T_YPTR: Gc.yptr.toI64();
			case T_YLIM: Gc.ylim.toI64();
			case T_YRLIM: Gc.yrlim.toI64();
			case _: Threads.self.toI64();
		}

	static function tlsSet(t:Int, v:I64)
		switch t {
			case T_SP: Gc.sp = Ptr.ofI64(v);
			case T_SP_HW: Gc.hw = Ptr.ofI64(v);
			case T_HCUR: Gc.hcur = Ptr.ofI64(v);
			case T_EXN: Gc.exn = Ptr.ofI64(v);
			case T_YPTR: Gc.yptr = Ptr.ofI64(v);
			case T_YLIM: Gc.ylim = Ptr.ofI64(v);
			case T_YRLIM: Gc.yrlim = Ptr.ofI64(v);
			case _: Threads.self = Ptr.ofI64(v);
		}

	// a call of an interpreted function: its arguments from the operands at
	// ip + 4 * first into its parameters' registers, its result into register d
	// (none: a word of its frame)
	static inline function callInterp(regs:Ptr, ip:Ptr, desc:Ptr, d:Int, n:Int, first:Int) {
		var callee = isp.add(FRAME);
		var nc = Mem.getI32(desc, H_NCONSTS);
		for (k in 0...n)
			Mem.setI64At(callee, 0, nc + k, gl(regs, o(ip, first + k)));
		run(desc, d >= 0 ? regs.add(d << 3) : isp.add(F_IP));
	}

	// a call through a call-out stub: buf[0] the function (indirect calls),
	// the arguments after it, the result into buf[0]
	static inline function callOut(regs:Ptr, ip:Ptr, stub:Ptr, fn:I64, d:Int, n:Int, first:Int) {
		var buf = isp;
		Mem.setI64(buf, 0, fn);
		for (k in 0...n)
			Mem.setI64At(buf, 8, k, gl(regs, o(ip, first + k)));
		isp = buf.add((8 * n + 23) & ~15);
		Mem.callRef2(stub, null, buf);
		isp = buf;
		if (d >= 0) sl(regs, d, Mem.getI64(buf, 0));
	}

	// ---- code loaded at run time (a Mir host, Mem.mirHost): no code of its own
	// (hxmc.interp.InterpAbi: the register image, its offsets; the call-outs
	// and the pools' entries are functions of the compiler)
	static inline var IMG_FN = 192;
	static inline var IMG_BYTES = 208;
	static inline var IMG_F0 = 16;
	// an argument's place in the image: its byte offset, and whether its low 32 bits are zero-extended
	static inline var ARG_ZEXT = 0x10000;
	// a call's result: an integer register, a float one, a struct in registers (its parts stored)
	static inline var R_INT = 0;
	static inline var R_FLOAT = 1;
	static inline var R_PARTS = 2;
	// SPECIAL's expansions
	static inline var SP_LOAD4 = 0;
	static inline var SP_LOAD8 = 1;
	static inline var SP_STORE4 = 2;
	static inline var SP_STORE8 = 3;
	static inline var SP_ADD4 = 4;
	static inline var SP_ADD8 = 5;
	static inline var SP_XCHG4 = 6;
	static inline var SP_XCHG8 = 7;
	static inline var SP_CAS4 = 8;
	static inline var SP_CAS8 = 9;
	static inline var SP_FENCE = 10;
	static inline var SP_F32_TO_F64 = 11;
	static inline var SP_F64_TO_F32 = 12;
	static inline var SP_F32BITS_TO_FREG = 13;
	static inline var SP_FREG_TO_F32BITS = 14;
	static inline var SP_FLOOR = 15; // (arm64's: x86-64 calls the C library's)
	static inline var SP_CEIL = 16;

	// native code at fn called through the image: the arguments' registers
	// at operand `first`, then the shape: the result's kind, the stack
	// words, each argument's place; with R_PARTS the struct's address
	// register, its parts and for each its result word, offset and bytes
	static function callX(regs:Ptr, ip:Ptr, fn:I64, d:Int, n:Int, first:Int) {
		if (Mem.mirHost() == 1) callXHost(regs, ip, fn, d, n, first);
		else throw "hxmc interp: CALLX outside a Mir host (a compiler with Mir macros)";
	}

	static function callXHost(regs:Ptr, ip:Ptr, fn:I64, d:Int, n:Int, first:Int) {
		var img = isp;
		var sh = first + n;
		var rk = o(ip, sh), nst = o(ip, sh + 1);
		for (k in 0...n) {
			var dst = o(ip, sh + 2 + k);
			var v = gl(regs, o(ip, first + k));
			Mem.setI64(img, dst & 0xFFFF, dst & ARG_ZEXT != 0 ? zext(v.toInt()) : v);
		}
		Mem.setI64(img, IMG_FN, fn);
		isp = img.add(IMG_BYTES);
		Mem.callRef2(nst > 0 ? Mem.sym("hxmc_interp_callout_s") : Mem.sym("hxmc_interp_callout_r"), null, img);
		isp = img;
		if (rk == R_INT) {
			if (d >= 0) sl(regs, d, Mem.getI64(img, 0));
		} else if (rk == R_FLOAT) {
			if (d >= 0) sl(regs, d, Mem.getI64(img, IMG_F0));
		} else {
			var at = sh + 2 + n;
			var addr = Ptr.ofI64(gl(regs, o(ip, at)));
			for (p in 0...o(ip, at + 1)) {
				var w = img.add(o(ip, at + 2 + 3 * p));
				var off = o(ip, at + 3 + 3 * p), size = o(ip, at + 4 + 3 * p);
				for (b in 0...size)
					Mem.setI8(addr, off + b, Mem.getU8(w, b));
			}
		}
	}

	static function special(regs:Ptr, ip:Ptr) {
		var d = o(ip, 2);
		inline function p():Ptr
			return Ptr.ofI64(gl(regs, o(ip, 3)));
		switch o(ip, 1) {
			case SP_LOAD4:
				si(regs, d, hxmc.unsafe.Atomic.load32(p()));
			case SP_LOAD8:
				sl(regs, d, hxmc.unsafe.Atomic.load64(p()));
			case SP_STORE4:
				hxmc.unsafe.Atomic.store32(p(), gi(regs, o(ip, 4)));
			case SP_STORE8:
				hxmc.unsafe.Atomic.store64(p(), gl(regs, o(ip, 4)));
			case SP_ADD4:
				si(regs, d, hxmc.unsafe.Atomic.add32(p(), gi(regs, o(ip, 4))));
			case SP_ADD8:
				sl(regs, d, hxmc.unsafe.Atomic.add64(p(), gl(regs, o(ip, 4))));
			case SP_XCHG4:
				si(regs, d, hxmc.unsafe.Atomic.exchange32(p(), gi(regs, o(ip, 4))));
			case SP_XCHG8:
				sl(regs, d, hxmc.unsafe.Atomic.exchange64(p(), gl(regs, o(ip, 4))));
			case SP_CAS4:
				si(regs, d, hxmc.unsafe.Atomic.cas32(p(), gi(regs, o(ip, 4)), gi(regs, o(ip, 5))));
			case SP_CAS8:
				sl(regs, d, hxmc.unsafe.Atomic.cas64(p(), gl(regs, o(ip, 4)), gl(regs, o(ip, 5))));
			case SP_FENCE:
				hxmc.unsafe.Atomic.fence();
			case SP_F32_TO_F64:
				// (through a word of the interpreter's stack)
				Mem.setI32(isp, 0, gi(regs, o(ip, 3)));
				sf(regs, d, Mem.getF32(isp, 0));
			case SP_F64_TO_F32:
				Mem.setF32(isp, 0, gf(regs, o(ip, 3)));
				si(regs, d, Mem.getI32(isp, 0));
			case SP_F32BITS_TO_FREG:
				// (a float's bits in the low half: a register move, the upper half zero)
				sl(regs, d, zext(gi(regs, o(ip, 3))));
			case SP_FLOOR:
				sf(regs, d, Math.ffloor(gf(regs, o(ip, 3))));
			case SP_CEIL:
				sf(regs, d, Math.fceil(gf(regs, o(ip, 3))));
			case _: // SP_FREG_TO_F32BITS
				si(regs, d, gi(regs, o(ip, 3)));
		}
	}

	// (a Mir host's: the program of a Mir host reaches these, macro.Loader,
	// interp.InterpAbi's entries)
	// the functions given entries of the pools, by entry number (InterpAbi.POOLS;
	// made at the first, as the table), the entries given out of each pool
	static var poolDescs:Ptr;
	static var poolUsed:Ptr;
	public static var entriesGiven = 0;

	// the address native code calls the interpreted function of descriptor
	// desc at: an entry of the pool of its kind (its result's, whether its
	// arguments take stack words: its flags, D_*), given out once and never
	// taken back (macro.Loader: the descriptor need not be written yet)
	public static function poolEntry(desc:Ptr, flags:Int):Ptr {
		if (flags & D_NOENTRY != 0) throw "hxmc interp: a function called from native code whose arguments take more stack words than the interpreter's entries (hxmc.interp.InterpAbi.STACK_WORDS)";
		var t = Mem.sym("hxmc_interp_pools");
		if (poolDescs.isNull()) {
			var total:I64 = 0;
			for (k in 0...4)
				total += Mem.getI64(t, 8 * k);
			poolDescs = LibC.malloc(total * 8);
			LibC.memset(poolDescs, 0, total * 8);
			poolUsed = LibC.malloc(32);
			LibC.memset(poolUsed, 0, 32);
		}
		var kind = (flags & D_STACK != 0 ? 2 : 0) + (flags & D_FLOAT != 0 ? 1 : 0);
		var base = 0;
		for (k in 0...kind)
			base += Mem.getI64(t, 8 * k).toInt();
		var used = Mem.getI64(poolUsed, 8 * kind).toInt();
		if (used == Mem.getI64(t, 8 * kind).toInt())
			throw "hxmc interp: out of entries for interpreted functions called from native code: all " + used + " of the pool of "
				+ ["integer", "double", "integer, stack", "double, stack"][kind] + " results are given out (hxmc.interp.InterpAbi.POOL_*)";
		Mem.setI64(poolUsed, 8 * kind, used + 1);
		var k = base + used;
		Mem.setPtr(poolDescs, 8 * k, desc);
		var addr = Mem.getPtr(t, 32 + 8 * k);
		register(addr, desc);
		entriesGiven++;
		return addr;
	}

	// the entries given out of each pool (HXMC_MACRO_STATS): integer, double, integer with stack words, double with
	public static function entriesByPool():String
		return poolUsed.isNull() ? "0/0/0/0" : [for (k in 0...4) Std.string(Mem.getI64(poolUsed, 8 * k))].join("/");

	// native code calling entry k of the pools (its common function): the
	// arguments from the register image img (the descriptor's parameter
	// sources), the result as a word (the common function returns it as its
	// kind's register)
	@:hxmc.export("hxmc_interp_pool_enter") static function poolEnter(k:Int, img:Ptr):I64 {
		var desc = Mem.getPtr(poolDescs, 8 * k);
		if (isp.isNull()) initStack();
		var base = isp;
		try {
			var regs = base.add(FRAME), nc = Mem.getI32(desc, H_NCONSTS);
			var src = desc.addL(Mem.getI64(desc, H_SOURCES));
			for (j in 0...Mem.getI32(desc, H_NPARAMS))
				Mem.setI64At(regs, 0, nc + j, Mem.getI64(img, Mem.getI32(src, 4 * j)));
			run(desc, img);
		} catch (e:Dynamic) {
			isp = base;
			throw e;
		}
		return Mem.getI64(img, 0);
	}

	// runs the frame from ip: RETURNED, or the level of the try its code
	// ended (where it goes on saved)
	static function exec(fr:Ptr, ip:Ptr):Int {
		var syms = Mem.getPtr(fr, F_SYMS);
		var regs = Mem.getPtr(fr, F_REGS);
		while (true) {
			switch (o(ip, 0) : IOp) {
				case TLSLD:
					sl(regs, o(ip, 1), tlsGet(o(ip, 2)));
					ip = ip.add(12);
				case TLSST:
					tlsSet(o(ip, 2), gl(regs, o(ip, 1)));
					ip = ip.add(12);
				case TLSST_HCUR:
					var v = Ptr.ofI64(gl(regs, o(ip, 1)));
					var prevOff = o(ip, 2);
					hprevOff = prevOff;
					Gc.hcur = v;
					ip = ip.add(12);
					// (a try of this frame's ended: back to its enterTry)
					var j = Mem.getI32(fr, F_NTRIES) - 1;
					while (j >= 0 && Mem.getPtr(Mem.getPtr(fr, F_TRIES + 8 * j), prevOff) != v)
						j--;
					if (j >= 0) {
						Mem.setI32(fr, F_NTRIES, j);
						Mem.setPtr(fr, F_IP, ip);
						return j;
					}
				case SADDR:
					sl(regs, o(ip, 1), Mem.getPtr(fr, F_SLOTS).add(o(ip, 2)).toI64());
					ip = ip.add(12);
				case MOV:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)));
					ip = ip.add(12);
				case ADD:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) + gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case SUB:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) - gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case MUL:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) * gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case AND:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) & gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case OR:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) | gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case XOR:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) ^ gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case NEG:
					sl(regs, o(ip, 1), -gl(regs, o(ip, 2)));
					ip = ip.add(12);
				case NOT:
					sl(regs, o(ip, 1), ~gl(regs, o(ip, 2)));
					ip = ip.add(12);
				case SHL32:
					si(regs, o(ip, 1), gi(regs, o(ip, 2)) << (gi(regs, o(ip, 3)) & 31));
					ip = ip.add(16);
				case SHL64:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) << (gi(regs, o(ip, 3)) & 63));
					ip = ip.add(16);
				case SAR32:
					si(regs, o(ip, 1), gi(regs, o(ip, 2)) >> (gi(regs, o(ip, 3)) & 31));
					ip = ip.add(16);
				case SAR64:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) >> (gi(regs, o(ip, 3)) & 63));
					ip = ip.add(16);
				case SHR32:
					si(regs, o(ip, 1), gi(regs, o(ip, 2)) >>> (gi(regs, o(ip, 3)) & 31));
					ip = ip.add(16);
				case SHR64:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) >>> (gi(regs, o(ip, 3)) & 63));
					ip = ip.add(16);
				case DIV32:
					var x:I64 = gi(regs, o(ip, 2)), y:I64 = gi(regs, o(ip, 3));
					si(regs, o(ip, 1), (x / y).toInt());
					ip = ip.add(16);
				case DIV64:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) / gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case REM32:
					si(regs, o(ip, 1), gi(regs, o(ip, 2)) % gi(regs, o(ip, 3)));
					ip = ip.add(16);
				case REM64:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)) % gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case ROTR32:
					var x = gi(regs, o(ip, 2)), k = gi(regs, o(ip, 3)) & 31;
					si(regs, o(ip, 1), k == 0 ? x : (x >>> k) | (x << (32 - k)));
					ip = ip.add(16);
				case ROTR64:
					var x = gl(regs, o(ip, 2)), k = gi(regs, o(ip, 3)) & 63;
					sl(regs, o(ip, 1), k == 0 ? x : (x >>> k) | (x << (64 - k)));
					ip = ip.add(16);
				case FADD:
					sf(regs, o(ip, 1), gf(regs, o(ip, 2)) + gf(regs, o(ip, 3)));
					ip = ip.add(16);
				case FSUB:
					sf(regs, o(ip, 1), gf(regs, o(ip, 2)) - gf(regs, o(ip, 3)));
					ip = ip.add(16);
				case FMUL:
					sf(regs, o(ip, 1), gf(regs, o(ip, 2)) * gf(regs, o(ip, 3)));
					ip = ip.add(16);
				case FDIV:
					sf(regs, o(ip, 1), gf(regs, o(ip, 2)) / gf(regs, o(ip, 3)));
					ip = ip.add(16);
				case FNEG:
					sf(regs, o(ip, 1), -gf(regs, o(ip, 2)));
					ip = ip.add(12);
				case FSQRT:
					sf(regs, o(ip, 1), Math.sqrt(gf(regs, o(ip, 2))));
					ip = ip.add(12);
				case FABS:
					sf(regs, o(ip, 1), Math.abs(gf(regs, o(ip, 2))));
					ip = ip.add(12);
				case EQ32:
					si(regs, o(ip, 1), b2i(gi(regs, o(ip, 2)) == gi(regs, o(ip, 3))));
					ip = ip.add(16);
				case NE32:
					si(regs, o(ip, 1), b2i(gi(regs, o(ip, 2)) != gi(regs, o(ip, 3))));
					ip = ip.add(16);
				case LT32:
					si(regs, o(ip, 1), b2i(gi(regs, o(ip, 2)) < gi(regs, o(ip, 3))));
					ip = ip.add(16);
				case LE32:
					si(regs, o(ip, 1), b2i(gi(regs, o(ip, 2)) <= gi(regs, o(ip, 3))));
					ip = ip.add(16);
				case GT32:
					si(regs, o(ip, 1), b2i(gi(regs, o(ip, 2)) > gi(regs, o(ip, 3))));
					ip = ip.add(16);
				case GE32:
					si(regs, o(ip, 1), b2i(gi(regs, o(ip, 2)) >= gi(regs, o(ip, 3))));
					ip = ip.add(16);
				case ULT32:
					si(regs, o(ip, 1), b2i((gi(regs, o(ip, 2)) ^ MIN32) < (gi(regs, o(ip, 3)) ^ MIN32)));
					ip = ip.add(16);
				case ULE32:
					si(regs, o(ip, 1), b2i((gi(regs, o(ip, 2)) ^ MIN32) <= (gi(regs, o(ip, 3)) ^ MIN32)));
					ip = ip.add(16);
				case UGT32:
					si(regs, o(ip, 1), b2i((gi(regs, o(ip, 2)) ^ MIN32) > (gi(regs, o(ip, 3)) ^ MIN32)));
					ip = ip.add(16);
				case UGE32:
					si(regs, o(ip, 1), b2i((gi(regs, o(ip, 2)) ^ MIN32) >= (gi(regs, o(ip, 3)) ^ MIN32)));
					ip = ip.add(16);
				case EQ64:
					si(regs, o(ip, 1), b2i(gl(regs, o(ip, 2)) == gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case NE64:
					si(regs, o(ip, 1), b2i(gl(regs, o(ip, 2)) != gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case LT64:
					si(regs, o(ip, 1), b2i(gl(regs, o(ip, 2)) < gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case LE64:
					si(regs, o(ip, 1), b2i(gl(regs, o(ip, 2)) <= gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case GT64:
					si(regs, o(ip, 1), b2i(gl(regs, o(ip, 2)) > gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case GE64:
					si(regs, o(ip, 1), b2i(gl(regs, o(ip, 2)) >= gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case ULT64:
					si(regs, o(ip, 1), b2i(Mem.ult(gl(regs, o(ip, 2)), gl(regs, o(ip, 3)))));
					ip = ip.add(16);
				case ULE64:
					si(regs, o(ip, 1), b2i(!Mem.ult(gl(regs, o(ip, 3)), gl(regs, o(ip, 2)))));
					ip = ip.add(16);
				case UGT64:
					si(regs, o(ip, 1), b2i(Mem.ult(gl(regs, o(ip, 3)), gl(regs, o(ip, 2)))));
					ip = ip.add(16);
				case UGE64:
					si(regs, o(ip, 1), b2i(!Mem.ult(gl(regs, o(ip, 2)), gl(regs, o(ip, 3)))));
					ip = ip.add(16);
				case FEQ:
					si(regs, o(ip, 1), b2i(gf(regs, o(ip, 2)) == gf(regs, o(ip, 3))));
					ip = ip.add(16);
				case FNE:
					si(regs, o(ip, 1), b2i(gf(regs, o(ip, 2)) != gf(regs, o(ip, 3))));
					ip = ip.add(16);
				case FLT:
					si(regs, o(ip, 1), b2i(gf(regs, o(ip, 2)) < gf(regs, o(ip, 3))));
					ip = ip.add(16);
				case FLE:
					si(regs, o(ip, 1), b2i(gf(regs, o(ip, 2)) <= gf(regs, o(ip, 3))));
					ip = ip.add(16);
				case FGT:
					si(regs, o(ip, 1), b2i(gf(regs, o(ip, 2)) > gf(regs, o(ip, 3))));
					ip = ip.add(16);
				case FGE:
					si(regs, o(ip, 1), b2i(gf(regs, o(ip, 2)) >= gf(regs, o(ip, 3))));
					ip = ip.add(16);
				case SEXT:
					sl(regs, o(ip, 1), (gi(regs, o(ip, 2)) : I64));
					ip = ip.add(12);
				case ZEXT:
					sl(regs, o(ip, 1), zext(gi(regs, o(ip, 2))));
					ip = ip.add(12);
				case TRUNC:
					si(regs, o(ip, 1), gl(regs, o(ip, 2)).toInt());
					ip = ip.add(12);
				case I2F32:
					sf(regs, o(ip, 1), gi(regs, o(ip, 2)));
					ip = ip.add(12);
				case I2F64:
					var f:Float = cast gl(regs, o(ip, 2));
					sf(regs, o(ip, 1), f);
					ip = ip.add(12);
				case F2I32:
					si(regs, o(ip, 1), Std.int(gf(regs, o(ip, 2))));
					ip = ip.add(12);
				case F2I64:
					var l:I64 = cast gf(regs, o(ip, 2));
					sl(regs, o(ip, 1), l);
					ip = ip.add(12);
				case SELECT:
					sl(regs, o(ip, 1), gi(regs, o(ip, 2)) != 0 ? gl(regs, o(ip, 3)) : gl(regs, o(ip, 4)));
					ip = ip.add(20);
				case LD1S:
					si(regs, o(ip, 1), Mem.getI8(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LD1U:
					si(regs, o(ip, 1), Mem.getU8(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LD2S:
					si(regs, o(ip, 1), Mem.getI16(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LD2U:
					si(regs, o(ip, 1), Mem.getU16(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LD4S:
					si(regs, o(ip, 1), Mem.getI32(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LD4U:
					sl(regs, o(ip, 1), zext(Mem.getI32(base(regs, ip, 2), o(ip, 3))));
					ip = ip.add(16);
				case LD8:
					sl(regs, o(ip, 1), Mem.getI64(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LDF4:
					sf(regs, o(ip, 1), Mem.getF32(base(regs, ip, 2), o(ip, 3)));
					ip = ip.add(16);
				case LDX1S:
					si(regs, o(ip, 1), Mem.getI8(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case LDX1U:
					si(regs, o(ip, 1), Mem.getU8(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case LDX2S:
					si(regs, o(ip, 1), Mem.getI16(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case LDX2U:
					si(regs, o(ip, 1), Mem.getU16(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case LDX4S:
					si(regs, o(ip, 1), Mem.getI32(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case LDX4U:
					sl(regs, o(ip, 1), zext(Mem.getI32(indexed(regs, ip, 2), o(ip, 5))));
					ip = ip.add(24);
				case LDX8:
					sl(regs, o(ip, 1), Mem.getI64(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case LDXF4:
					sf(regs, o(ip, 1), Mem.getF32(indexed(regs, ip, 2), o(ip, 5)));
					ip = ip.add(24);
				case ST1:
					Mem.setI8(base(regs, ip, 1), o(ip, 2), gi(regs, o(ip, 3)));
					ip = ip.add(16);
				case ST2:
					Mem.setI16(base(regs, ip, 1), o(ip, 2), gi(regs, o(ip, 3)));
					ip = ip.add(16);
				case ST4:
					Mem.setI32(base(regs, ip, 1), o(ip, 2), gi(regs, o(ip, 3)));
					ip = ip.add(16);
				case ST8:
					Mem.setI64(base(regs, ip, 1), o(ip, 2), gl(regs, o(ip, 3)));
					ip = ip.add(16);
				case STF4:
					Mem.setF32(base(regs, ip, 1), o(ip, 2), gf(regs, o(ip, 3)));
					ip = ip.add(16);
				case STX1:
					Mem.setI8(indexed(regs, ip, 1), o(ip, 4), gi(regs, o(ip, 5)));
					ip = ip.add(24);
				case STX2:
					Mem.setI16(indexed(regs, ip, 1), o(ip, 4), gi(regs, o(ip, 5)));
					ip = ip.add(24);
				case STX4:
					Mem.setI32(indexed(regs, ip, 1), o(ip, 4), gi(regs, o(ip, 5)));
					ip = ip.add(24);
				case STX8:
					Mem.setI64(indexed(regs, ip, 1), o(ip, 4), gl(regs, o(ip, 5)));
					ip = ip.add(24);
				case STXF4:
					Mem.setF32(indexed(regs, ip, 1), o(ip, 4), gf(regs, o(ip, 5)));
					ip = ip.add(24);
				case CALLN:
					var n = o(ip, 3);
					callOut(regs, ip, Mem.getPtr(syms, o(ip, 1) << 3), 0, o(ip, 2), n, 4);
					ip = ip.add(16 + 4 * n);
				case CALLNI:
					var n = o(ip, 4);
					var fn = gl(regs, o(ip, 2));
					// (an entry stub: its function run here; the last two entries cached at the call)
					var ic = syms.add(o(ip, 5) << 3);
					var e = Mem.getPtr(ic, 0);
					if (e.isNull() || Mem.getI64(e, 0) != fn) {
						var e2 = Mem.getPtr(ic, 8);
						if (!e2.isNull() && Mem.getI64(e2, 0) == fn) e = e2 else {
							e2 = lookup(fn);
							if (!e2.isNull()) {
								Mem.setPtr(ic, 8, e);
								Mem.setPtr(ic, 0, e2);
							}
							e = e2;
						}
					}
					if (!e.isNull()) callInterp(regs, ip, Mem.getPtr(e, 8), o(ip, 3), n, 6) else callOut(regs, ip, Mem.getPtr(syms, o(ip, 1) << 3), fn, o(ip, 3), n, 6);
					ip = ip.add(24 + 4 * n);
				case CALLI:
					var n = o(ip, 3);
					callInterp(regs, ip, Mem.getPtr(syms, o(ip, 1) << 3), o(ip, 2), n, 4);
					ip = ip.add(16 + 4 * n);
				case SETJMP:
					var r = enterTry(fr, ip.add(12), o(ip, 1), Ptr.ofI64(gl(regs, o(ip, 2))));
					if (r != CONTINUE) return r;
					ip = Mem.getPtr(fr, F_IP);
				case JMP:
					ip = ip.add(o(ip, 1));
				case MOVJ1:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)));
					ip = ip.add(o(ip, 3));
				case MOVJ2:
					sl(regs, o(ip, 1), gl(regs, o(ip, 2)));
					sl(regs, o(ip, 3), gl(regs, o(ip, 4)));
					ip = ip.add(o(ip, 5));
				case MOVJN:
					var n = o(ip, 1);
					var m = ip.add(8);
					for (_ in 0...n) {
						sl(regs, o(m, 0), gl(regs, o(m, 1)));
						m = m.add(8);
					}
					ip = ip.add(o(m, 0));
				case BR:
					ip = ip.add(gi(regs, o(ip, 1)) != 0 ? o(ip, 2) : o(ip, 3));
				case BEQ32:
					ip = ip.add(gi(regs, o(ip, 1)) == gi(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BNE32:
					ip = ip.add(gi(regs, o(ip, 1)) != gi(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BLT32:
					ip = ip.add(gi(regs, o(ip, 1)) < gi(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BLE32:
					ip = ip.add(gi(regs, o(ip, 1)) <= gi(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BGT32:
					ip = ip.add(gi(regs, o(ip, 1)) > gi(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BGE32:
					ip = ip.add(gi(regs, o(ip, 1)) >= gi(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BULT32:
					ip = ip.add((gi(regs, o(ip, 1)) ^ MIN32) < (gi(regs, o(ip, 2)) ^ MIN32) ? o(ip, 3) : o(ip, 4));
				case BULE32:
					ip = ip.add((gi(regs, o(ip, 1)) ^ MIN32) <= (gi(regs, o(ip, 2)) ^ MIN32) ? o(ip, 3) : o(ip, 4));
				case BUGT32:
					ip = ip.add((gi(regs, o(ip, 1)) ^ MIN32) > (gi(regs, o(ip, 2)) ^ MIN32) ? o(ip, 3) : o(ip, 4));
				case BUGE32:
					ip = ip.add((gi(regs, o(ip, 1)) ^ MIN32) >= (gi(regs, o(ip, 2)) ^ MIN32) ? o(ip, 3) : o(ip, 4));
				case BEQ64:
					ip = ip.add(gl(regs, o(ip, 1)) == gl(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BNE64:
					ip = ip.add(gl(regs, o(ip, 1)) != gl(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BLT64:
					ip = ip.add(gl(regs, o(ip, 1)) < gl(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BLE64:
					ip = ip.add(gl(regs, o(ip, 1)) <= gl(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BGT64:
					ip = ip.add(gl(regs, o(ip, 1)) > gl(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BGE64:
					ip = ip.add(gl(regs, o(ip, 1)) >= gl(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BULT64:
					ip = ip.add(Mem.ult(gl(regs, o(ip, 1)), gl(regs, o(ip, 2))) ? o(ip, 3) : o(ip, 4));
				case BULE64:
					ip = ip.add(!Mem.ult(gl(regs, o(ip, 2)), gl(regs, o(ip, 1))) ? o(ip, 3) : o(ip, 4));
				case BUGT64:
					ip = ip.add(Mem.ult(gl(regs, o(ip, 2)), gl(regs, o(ip, 1))) ? o(ip, 3) : o(ip, 4));
				case BUGE64:
					ip = ip.add(!Mem.ult(gl(regs, o(ip, 1)), gl(regs, o(ip, 2))) ? o(ip, 3) : o(ip, 4));
				case BFEQ:
					ip = ip.add(gf(regs, o(ip, 1)) == gf(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BFNE:
					ip = ip.add(gf(regs, o(ip, 1)) != gf(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BFLT:
					ip = ip.add(gf(regs, o(ip, 1)) < gf(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BFLE:
					ip = ip.add(gf(regs, o(ip, 1)) <= gf(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BFGT:
					ip = ip.add(gf(regs, o(ip, 1)) > gf(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case BFGE:
					ip = ip.add(gf(regs, o(ip, 1)) >= gf(regs, o(ip, 2)) ? o(ip, 3) : o(ip, 4));
				case SWITCH:
					var v = gi(regs, o(ip, 1));
					var n = o(ip, 2);
					var t = o(ip, 3 + 2 * n);
					for (k in 0...n)
						if (o(ip, 3 + 2 * k) == v) {
							t = o(ip, 4 + 2 * k);
							break;
						}
					ip = ip.add(t);
				case SWITCHT:
					var v = gi(regs, o(ip, 1)) - o(ip, 2);
					var n = o(ip, 3);
					ip = ip.add(v >= 0 && v < n ? o(ip, 4 + v) : o(ip, 4 + n));
				case RET:
					Mem.setI64(Mem.getPtr(fr, F_RES), 0, gl(regs, o(ip, 1)));
					return RETURNED;
				case RETV:
					return RETURNED;
				case TLSXLD:
					sl(regs, o(ip, 1), Mem.getI64At(tlsBlock(), 0, o(ip, 2)));
					ip = ip.add(12);
				case TLSXST:
					Mem.setI64At(tlsBlock(), 0, o(ip, 2), gl(regs, o(ip, 1)));
					ip = ip.add(12);
				case CALLX:
					callX(regs, ip, gl(regs, o(ip, 1)), o(ip, 2), o(ip, 4), 5);
					ip = ip.add(4 * o(ip, 3));
				case CALLXI:
					var n = o(ip, 5);
					var fn = gl(regs, o(ip, 1));
					// (an interpreted function's entry: run here; the last two cached at the call)
					var ic = syms.add(o(ip, 4) << 3);
					var e = Mem.getPtr(ic, 0);
					if (e.isNull() || Mem.getI64(e, 0) != fn) {
						var e2 = Mem.getPtr(ic, 8);
						if (!e2.isNull() && Mem.getI64(e2, 0) == fn) e = e2 else {
							e2 = lookup(fn);
							if (!e2.isNull()) {
								Mem.setPtr(ic, 8, e);
								Mem.setPtr(ic, 0, e2);
							}
							e = e2;
						}
					}
					if (!e.isNull()) callInterp(regs, ip, Mem.getPtr(e, 8), o(ip, 2), n, 6) else callX(regs, ip, fn, o(ip, 2), n, 6);
					ip = ip.add(4 * o(ip, 3));
				case SPECIAL:
					special(regs, ip);
					ip = ip.add(24);
				case FENCE:
					hxmc.unsafe.Atomic.fence();
					ip = ip.add(4);
				case LAZY:
					return lazy(fr, ip);
				case UDIV64:
					sl(regs, o(ip, 1), udiv(gl(regs, o(ip, 2)), gl(regs, o(ip, 3))));
					ip = ip.add(16);
				case UREM64:
					var x = gl(regs, o(ip, 2)), y = gl(regs, o(ip, 3));
					sl(regs, o(ip, 1), x - udiv(x, y) * y);
					ip = ip.add(16);
				case UNREACH:
					throw "hxmc interp: unreachable code reached";
				case _:
					throw "hxmc interp: no operation " + o(ip, 0);
			}
		}
	}
}
