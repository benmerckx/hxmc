package hxmc;

import haxe.ds.Vector;
import core.ds.VectorTools.vector;
import hxmc.Mir;

// where one argument (or parameter) travels
class ArgLoc {
	// a register, or -1: on the stack
	public var reg:Int;
	// on the stack: its byte offset among the stack arguments (Win64: counting
	// the shadow space) and its bytes
	public var off = 0;
	public var size = 8;
	// Win64, a variadic call: a float also travels as its bits in this
	// integer register (the callee may read either)
	public var gpr = -1;
	// Windows arm64, a variadic call: a float travels as its bits instead,
	// in reg (an integer register) or on the stack
	public var bits = false;

	public function new(reg:Int)
		this.reg = reg;

	public static function stack(off:Int, size:Int):ArgLoc {
		var l = new ArgLoc(-1);
		l.off = off;
		l.size = size;
		return l;
	}
}

// the places of the arguments of one call, or of a function's parameters
class Placement {
	public var locs:Vector<ArgLoc>;
	// the bytes of the outgoing argument area the call needs
	public var stack = 0;

	public function new(n:Int)
		locs = new Vector(n);
}

// One calling convention per ABI: the argument and result registers, the
// registers a call clobbers and the ones it keeps, and where each argument
// of a signature goes. Both sides use it, the caller for a call's arguments
// (IselBase.call) and the callee for its parameters (IselBase.param), so they
// cannot disagree; CAbi classifies the structs by value that come in as
// parts (MIns.cGroups, MFunc.cParams).
// Register numbers are LIR's: x86-64's general registers 0-15 and xmm0-15
// as 16-31; arm64's x0-x30 as 0-30 and d0-d31 as 32-63.
class CallConv {
	public var argGprs(default, null):Vector<Int>;
	// the first float argument register, and how many there are
	public var argFpr0(default, null):Int;
	public var argFprs(default, null):Int;
	public var callerSaved(default, null):Vector<Int>;
	public var calleeSaved(default, null):Vector<Int>;
	// the registers a call defines (Regalloc.RegTarget.callResults)
	public var callResults(default, null):Vector<Int>;
	// the integer result registers in order (a struct's integer parts)
	public var intResults(default, null):Vector<Int>;
	// where a callee finds the address to store a struct result at (arm64:
	// x8); -1: it is a first argument
	public var sretReg(default, null) = -1;

	public static function of(abi:Abi):CallConv
		return abi.arm ? new Aapcs64(abi.os == "macos", abi.os == "windows") : x64(abi.os == "windows");

	public static function x64(win:Bool):CallConv
		return win ? Win64.get() : SysV.get();

	// where each of the first n arguments of a signature goes: their types,
	// their struct groups (MIns.cGroups; empty: each its own), C sizes
	// (MIns.cSizes; empty: by type) and the first variadic one (-1: none)
	public function place(tys:Vector<MTy>, n:Int, groups:Vector<Int>, sizes:Vector<Int>, variadic:Int):Placement
		throw "abstract";

	// the arguments of a call (n: without a struct result's address)
	public inline function call(i:MIns, n:Int):Placement
		return place(i.argTys, n, i.cGroups, i.cSizes, i.variadic);

	// the parameters of a function
	public inline function params(m:MFunc):Placement
		return place(m.params, m.params.length, m.cParams, m.cParamSizes, -1);

	// the register of a scalar result
	public inline function result(float:Bool):Int
		return float ? argFpr0 : intResults[0];

	// the register of each part of a struct result in registers (MIns.cRet,
	// MFunc.cRet): integer parts in the integer result registers in order,
	// float ones in the float result registers
	public function structResult(parts:Vector<CAbi.CPart>):Vector<Int> {
		var r = new Vector<Int>(parts.length), gk = 0, fk = 0;
		for (k in 0...parts.length)
			r[k] = parts[k].float ? argFpr0 + fk++ : intResults[gk++];
		return r;
	}

	function new() {}
}

// System V x86-64 (Linux, macOS): integer arguments in rdi, rsi, rdx, rcx,
// r8, r9 and floats in xmm0-7 by class, the rest in 8-byte stack slots; a
// struct's parts in registers when enough of both kinds are left, else all on
// the stack (its memory, in 8-byte words), as a MEMORY struct's always
class SysV extends CallConv {
	static var inst:Null<SysV>;

	public static function get():SysV {
		if (inst == null) inst = new SysV();
		return inst;
	}

	function new() {
		super();
		argGprs = vector(7, 6, 2, 1, 8, 9);
		argFpr0 = 16;
		argFprs = 8;
		callerSaved = vector(0, 1, 2, 6, 7, 8, 9, 10, 11, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);
		calleeSaved = vector(3, 5, 12, 13, 14, 15);
		callResults = vector(0, 2, 16, 17);
		intResults = vector(0, 2);
	}

	override public function place(tys:Vector<MTy>, n:Int, groups:Vector<Int>, sizes:Vector<Int>, variadic:Int):Placement {
		// (a struct's parts are all in tys: its last one may come after n)
		var p = new Placement(tys.length);
		var gi = 0, fi = 0, si = 0, k = 0;
		while (k < n) {
			var g = groups.length > 0 ? groups[k] : 1;
			var cnt = g < 0 ? -g : g > 0 ? g : 1;
			var ni = 0, nf = 0;
			for (j in k...k + cnt)
				if (tys[j] == F64) nf++ else ni++;
			var regs = g > 0 && gi + ni <= argGprs.length && fi + nf <= argFprs;
			for (j in k...k + cnt)
				p.locs[j] = !regs ? ArgLoc.stack(8 * si++, 8) : new ArgLoc(tys[j] == F64 ? argFpr0 + fi++ : argGprs[gi++]);
			k += cnt;
		}
		p.stack = 8 * si;
		return p;
	}
}

// Win64: the first four arguments by position in rcx, rdx, r8, r9 or
// xmm0-3, the rest in 8-byte stack slots after 32 bytes of shadow space the
// caller always reserves; rsi, rdi and xmm6-15 are callee-saved. A variadic
// callee reads a float from the integer register of its position too.
class Win64 extends CallConv {
	static var inst:Null<Win64>;

	public static function get():Win64 {
		if (inst == null) inst = new Win64();
		return inst;
	}

	function new() {
		super();
		argGprs = vector(1, 2, 8, 9);
		argFpr0 = 16;
		argFprs = 4;
		callerSaved = vector(0, 1, 2, 8, 9, 10, 11, 16, 17, 18, 19, 20, 21);
		calleeSaved = vector(3, 5, 6, 7, 12, 13, 14, 15, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);
		callResults = vector(0, 2, 16, 17);
		intResults = vector(0, 2);
	}

	override public function place(tys:Vector<MTy>, n:Int, groups:Vector<Int>, sizes:Vector<Int>, variadic:Int):Placement {
		var p = new Placement(n);
		for (k in 0...n) {
			if (k >= 4) {
				p.locs[k] = ArgLoc.stack(8 * k, 8);
				continue;
			}
			var l = new ArgLoc(tys[k] == F64 ? argFpr0 + k : argGprs[k]);
			if (variadic >= 0 && tys[k] == F64) l.gpr = argGprs[k];
			p.locs[k] = l;
		}
		p.stack = 8 * (n > 4 ? n : 4);
		return p;
	}
}

// AAPCS64 (Linux, Android, Windows and Apple on arm64): integer arguments in
// x0-x7, floats in d0-d7 (s0-s7), the rest on the stack in 8-byte slots; a
// struct's parts in registers when enough of their kind are left, else all
// on the stack as its memory (at an 8-byte boundary), and no later argument
// of that kind in registers. A struct result's address is in x8.
// - Apple: stack arguments packed by their C size (and a struct's memory
//   aligned to its parts), variadic arguments on the stack, 8 bytes each.
// - Windows: a variadic call passes every argument as an integer (x0-x7,
//   then the stack), floats as their bits.
class Aapcs64 extends CallConv {
	public var apple(default, null):Bool;
	public var win(default, null):Bool;

	public function new(apple:Bool, win:Bool) {
		super();
		this.apple = apple;
		this.win = win;
		argGprs = vector(0, 1, 2, 3, 4, 5, 6, 7);
		argFpr0 = 32;
		argFprs = 8;
		callerSaved = vector(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 32, 33, 34, 35, 36, 37, 38, 39, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
			59, 60, 61, 62, 63);
		calleeSaved = CALLEE_SAVED;
		callResults = vector(0, 1, 32, 33, 34, 35);
		intResults = vector(0, 1);
		sretReg = 8;
	}

	// (the emitter's frame needs them before any function is selected)
	public static final CALLEE_SAVED:Vector<Int> = vector(19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 40, 41, 42, 43, 44, 45, 46, 47);

	override public function place(tys:Vector<MTy>, n:Int, groups:Vector<Int>, sizes:Vector<Int>, variadic:Int):Placement {
		var p = new Placement(n);
		var gi = 0, fi = 0, stack = 0;
		// the parts of a struct argument left to place on the stack (none in registers)
		var spill = 0;
		for (k in 0...n) {
			var t = tys[k];
			var parts = groups.length > 0 ? groups[k] : 1;
			if (parts > 1 && (t == F64 ? fi : gi) + parts > 8) {
				if (t == F64) fi = 8 else gi = 8;
				spill = parts;
				var al = apple ? sizes[k] : 8;
				stack = (stack + al - 1) & ~(al - 1);
			}
			if (apple && variadic >= 0 && k >= variadic) {
				stack = (stack + 7) & ~7;
				p.locs[k] = ArgLoc.stack(stack, 8);
				stack += 8;
				continue;
			}
			if (t == F64 && win && variadic >= 0) {
				var l:ArgLoc;
				if (gi < 8) l = new ArgLoc(argGprs[gi++]) else {
					l = ArgLoc.stack(stack, 8);
					stack += 8;
				}
				l.bits = true;
				p.locs[k] = l;
				continue;
			}
			if (t == F64) {
				if (fi < 8) {
					p.locs[k] = new ArgLoc(argFpr0 + fi++);
					continue;
				}
			} else if (gi < 8) {
				p.locs[k] = new ArgLoc(argGprs[gi++]);
				continue;
			}
			// (8-byte slots, except inside a struct, whose memory they are)
			var size = !apple && spill == 0 ? 8 : k < sizes.length ? sizes[k] : t == I32 ? 4 : 8;
			stack = (stack + size - 1) & ~(size - 1);
			if (spill > 0) spill--;
			p.locs[k] = ArgLoc.stack(stack, size);
			stack += size;
		}
		p.stack = (stack + 7) & ~7;
		return p;
	}
}
