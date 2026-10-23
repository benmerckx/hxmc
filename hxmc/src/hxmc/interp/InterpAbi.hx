package hxmc.interp;

import core.ds.VectorTools.vector;
import haxe.ds.Vector;
import hxmc.Mir;
import hxmc.Obj;
import hxmc.CallConv.ArgLoc;

// How interpreted code loaded at run time (macro.Loader: -D hxmc.mir-macros,
// -D hxmc.mir-run) meets native code without code of its own: every
// crossing goes through a register image, a buffer of words that the
// interpreter (hxmc.rt.Interp) reads and writes and that a few functions
// of the compiler (built with -D hxmc.jit) move in and out of the ABI's
// registers. Those functions are Mir, compiled by the target's own back end
// like any other (`thunks`): nothing here is machine code.
//
// The image (byte offsets): the integer argument registers in the calling
// convention's order (8 words: System V's 6 used, Win64's 4), the float ones
// (8 words), then STACK_WORDS words of stack arguments as the ABI lays them
// out (Placement.off; Win64: after the shadow space), then the callee's address (call-outs). A call's results
// come back in the first 4 words: the first two integer and the first two
// float result registers.
//
// - Call-outs (interpreted code calling native code): hxmc_interp_callout_r
//   (no stack argument) and hxmc_interp_callout_s load every argument
//   register of the image and call the address at FN with them, the stack
//   words as further arguments; the result registers are taken as the
//   parts of a struct result in registers (MIns.cRet), so all four land in
//   the image. InterpGen places each argument by the convention
//   (CallConv.place) at compile time.
// - Entries (native code calling an interpreted function: dispatch rows,
//   method tables, closures, makers, the compiler's own callbacks): a pool
//   of functions in the compiler, POOL_INT and POOL_FLOAT of each kind
//   (`pools`), each taking every argument register (and STACK_WORDS stack
//   words in the `s` pools) and passing them with its number k to its
//   pool's common function, which writes the image and calls
//   hxmc_interp_pool_enter(k, image): the interpreter runs the function the
//   loader gave entry k (a descriptor's parameter sources: byte offsets in
//   the image, InterpGen). The `f` pools return a double, the others an
//   integer. Pool entries are given out once, when a function's address is
//   first needed (Loader), and never taken back.
//
// The call-outs, the common functions and the entries take every argument
// register, then the stack words (CallConv.ALL_REGS, MFunc.allRegs): one
// signature whatever the function behind them takes. The result registers
// come back as the parts of a struct result in hxmc's own registers for them
// (CallConv.structResult), whatever the ABI returns a C struct in. Per ABI:
// - System V x86-64 (Linux, macOS): a variadic callee reads al; the
//   call-outs set it (variadic from the stack words on).
// - AAPCS64 (Linux, Android, macOS, iOS, Windows): x18 is the platform's
//   register, which no function here uses (a64.Isel). A C function returning
//   a struct through x8 (no registers: MIns.structRet with empty cRet) needs
//   a call-out that passes x8: not written yet (InterpGen rejects such a
//   call).
//   - Apple: stack arguments are packed by their C size, and a variadic
//     argument takes an 8-byte stack slot: the image holds each at its byte
//     offset (Placement.off), which the stack words carry as they are (the
//     entries' and call-outs' stack words are 8 bytes each, packed
//     the same).
//   - Windows: a variadic call passes floats as integers (ArgLoc.bits), in
//     the integer registers' words: the call-outs are not variadic.
// - Win64: arguments take registers by position, the first four each in
//   rcx, rdx, r8, r9 or xmm0-3 by its kind, the rest on the stack after 32
//   bytes of shadow space. ALL_REGS places the call-outs', common functions'
//   and entries' integer parameters in rcx-r9 and float ones in xmm0-3, both
//   registers of each position: an entry takes what its caller passed in
//   either, and a call-out passes both. Interpreted code leaves a call's
//   first four arguments in the integer words by position (`outSlot`),
//   which the call-outs pass in both registers of the position: a variadic
//   callee, which reads a float from the integer register (ArgLoc.gpr), sees
//   it too. The image's stack words are the stack positions from 4 on.
@:access(hxmc.MirBuild)
@:access(hxmc.MirWriter)
class InterpAbi {
	public static inline var GPR = 0;
	public static inline var FPR = 64;
	public static inline var STACK = 128;
	public static inline var STACK_WORDS = 8;
	public static inline var FN = STACK + 8 * STACK_WORDS;
	public static inline var IMAGE_BYTES = FN + 16;
	// results: the integer result registers' words, then the float ones'
	public static inline var RES_INT0 = 0;
	public static inline var RES_INT1 = 8;
	public static inline var RES_F0 = 16;
	public static inline var RES_F1 = 24;
	// the pools (entries per kind: integer or no result, double result; register arguments only, or stack ones too)
	public static inline var POOL_INT = 6144;
	public static inline var POOL_FLOAT = 1024;
	public static inline var POOL_INT_STACK = 512;
	public static inline var POOL_FLOAT_STACK = 128;
	public static inline var POOLS = "hxmc_interp_pools";
	public static inline var CALLOUT_R = "hxmc_interp_callout_r";
	public static inline var CALLOUT_S = "hxmc_interp_callout_s";
	public static inline var ENTER = "hxmc_interp_pool_enter";
	// the host's thread-local variables, read and set by functions of the compiler (Loader, HostTable)
	public static inline var TLS_GET = "hxmc_tls_get$";
	public static inline var TLS_SET = "hxmc_tls_set$";

	// whether the target's convention is one of those above
	public static function supported(abi:Abi):Bool
		return !abi.wasm;

	static function check(abi:Abi) {
		if (!supported(abi)) throw new MirBuild.Unsupported("-D hxmc.jit: interpreted code loaded at run time on " + abi.name + " (hxmc.interp.InterpAbi)");
	}

	// the first variadic argument of a call-out (System V: al bounds the float
	// registers used; Win64: every register, CallConv.ALL_REGS), -1: none
	static function variadic(abi:Abi, cc:CallConv):Int
		return cc.positional ? CallConv.ALL_REGS : !abi.arm ? cc.argGprs.length + cc.argFprs : -1;

	// the bytes of a stack argument's offset (Placement.off) before the
	// image's first stack word (Win64: the shadow space)
	static inline function stackSkip(cc:CallConv):Int
		return cc.positional ? 32 : 0;

	// where an argument of a function entered through the pools travels, as a
	// byte offset in the image; -1: not there (an argument on the stack beyond
	// the image's stack words)
	public static function slot(cc:CallConv, loc:ArgLoc, float:Bool):Int {
		if (loc.reg < 0) {
			var off = loc.off - stackSkip(cc);
			return off >= 0 && off + loc.size <= 8 * STACK_WORDS ? STACK + off : -1;
		}
		if (loc.reg >= cc.argFpr0 && loc.reg < cc.argFpr0 + cc.argFprs && !loc.bits) return FPR + 8 * (loc.reg - cc.argFpr0);
		for (k in 0...cc.argGprs.length)
			if (cc.argGprs[k] == loc.reg) return GPR + 8 * k;
		return -1;
	}

	// where an argument of a call-out goes, as a byte offset in the image; -1:
	// not there. Win64: a register argument in the integer word of its
	// position, passed in both registers of the position (a variadic float
	// with them: ArgLoc.gpr)
	public static function outSlot(cc:CallConv, loc:ArgLoc, float:Bool):Int {
		if (cc.positional && loc.reg >= 0) {
			if (loc.reg >= cc.argFpr0) return loc.reg < cc.argFpr0 + cc.argFprs ? GPR + 8 * (loc.reg - cc.argFpr0) : -1;
			for (k in 0...cc.argGprs.length)
				if (cc.argGprs[k] == loc.reg) return GPR + 8 * k;
			return -1;
		}
		return loc.gpr >= 0 ? -1 : slot(cc, loc, float);
	}

	// whether a placement puts an argument on the stack (the pools and
	// call-outs with stack words; Win64 always reserves the shadow space)
	public static function onStack(pl:CallConv.Placement):Bool {
		for (l in pl.locs)
			if (l != null && l.reg < 0) return true;
		return false;
	}

	// the result word a struct part's register lands in
	public static function resultWord(cc:CallConv, reg:Int):Int {
		if (reg == cc.intResults[0]) return RES_INT0;
		if (cc.intResults.length > 1 && reg == cc.intResults[1]) return RES_INT1;
		if (reg == cc.argFpr0) return RES_F0;
		if (reg == cc.argFpr0 + 1) return RES_F1;
		return -1;
	}

	// the parameter types of the entries and call-outs: every argument register, then the stack words
	static function regParams(cc:CallConv, stack:Bool):Array<MTy> {
		var ps:Array<MTy> = [];
		for (_ in 0...cc.argGprs.length)
			ps.push(I64);
		for (_ in 0...cc.argFprs)
			ps.push(F64);
		if (stack)
			for (_ in 0...STACK_WORDS)
				ps.push(I64);
		return ps;
	}

	// the image's byte offset of parameter k of regParams (a call-out's: Win64
	// passes a position's two registers from its integer word, outSlot)
	static function paramOffset(cc:CallConv, k:Int, out:Bool):Int {
		var ng = cc.argGprs.length, nf = cc.argFprs;
		return k < ng ? GPR + 8 * k : k < ng + nf ? (out && cc.positional ? GPR : FPR) + 8 * (k - ng) : STACK + 8 * (k - ng - nf);
	}

	// the functions of the compiler (built with -D hxmc.jit) that code loaded
	// for the interpreter crosses into native code through
	public static function thunks(prep:Prep, abi:Abi, compile:MFunc->Void) {
		check(abi);
		var cc = CallConv.of(abi);
		for (stack in [false, true])
			compile(callout(prep, abi, cc, stack));
		var base = 0;
		for (kd in KINDS) {
			compile(common(prep, abi, cc, kd.name, kd.float, kd.stack));
			for (k in 0...kd.n)
				compile(entry(prep, abi, cc, kd.name, kd.float, kd.stack, k, base + k));
			base += kd.n;
		}
	}

	// the pools in order (an entry's number counts the entries of the pools before its own)
	static final KINDS = [
		{name: "i", float: false, stack: false, n: POOL_INT},
		{name: "f", float: true, stack: false, n: POOL_FLOAT},
		{name: "is", float: false, stack: true, n: POOL_INT_STACK},
		{name: "fs", float: true, stack: true, n: POOL_FLOAT_STACK}
	];

	// the table of the pools' entries (hxmc.rt.Interp: POOLS, the number of
	// entries of each pool, then every entry's address by its number)
	public static function poolTables(obj:Obj) {
		var sec = obj.section(".data", SecKind.Data, 16);
		var b = sec.buf;
		b.align(16);
		var start = b.len;
		for (kd in KINDS)
			b.u64(kd.n, 0);
		for (kd in KINDS)
			for (k in 0...kd.n) {
				sec.relocs.push(new Reloc(b.len, RelKind.RAbs64, obj.sym(entryName(kd.name, k)), 0));
				b.u64(0, 0);
			}
		obj.define(POOLS, sec, start, b.len - start, true);
	}

	static inline function entryName(kind:String, k:Int):String
		return "hxmc_interp_pe$" + kind + "$" + k;

	// (unused, image) -> 0: the function at FN called with the image's argument registers (and stack words), its result registers into the image
	static function callout(prep:Prep, abi:Abi, cc:CallConv, stack:Bool):MFunc {
		var tys = regParams(cc, stack);
		return MirBuild.synthetic(prep, abi, stack ? CALLOUT_S : CALLOUT_R, vector(I64, I64), I64, (b, ps) -> {
			var img = ps[1];
			var xs = [for (k in 0...tys.length) b.load(tys[k], 8, img, paramOffset(cc, k, true))];
			var fn = b.load(I64, 8, img, FN);
			// (the result's address: the struct result's, the image itself)
			xs.push(img);
			var x = b.mk(Call, Void);
			x.a = fn;
			x.args = Vector.fromArrayCopy(xs);
			x.argTys = Vector.fromArrayCopy(tys.concat([I64]));
			x.variadic = variadic(abi, cc);
			x.structRet = true;
			x.cRet = vector({off: RES_INT0, size: 8, float: false}, {off: RES_INT1, size: 8, float: false}, {off: RES_F0, size: 8, float: true},
				{off: RES_F1, size: 8, float: true});
			b.add(x);
			b.ret(b.lconst(0, 0));
		});
	}

	// a pool's common function: its entries' arguments and number into the image, the interpreter
	static function common(prep:Prep, abi:Abi, cc:CallConv, kind:String, float:Bool, stack:Bool):MFunc {
		var tys = regParams(cc, stack);
		var params = Vector.fromArrayCopy(tys.concat([I32]));
		var mf = MirBuild.synthetic(prep, abi, "hxmc_interp_pc$" + kind, params, float ? F64 : I64, (b, ps) -> {
			var img = b.stackAddr(b.f.slot(IMAGE_BYTES, 16));
			for (k in 0...tys.length)
				b.store(8, img, paramOffset(cc, k, false), ps[k]);
			var r = b.call(ENTER, vector(ps[tys.length], img), I64);
			b.ret(float ? b.op1(BitsToF, F64, r) : r);
		});
		mf.allRegs = true;
		return mf;
	}

	// entry k of a pool: its arguments as they came, and k, to the common function
	static function entry(prep:Prep, abi:Abi, cc:CallConv, kind:String, float:Bool, stack:Bool, k:Int, number:Int):MFunc {
		var tys = Vector.fromArrayCopy(regParams(cc, stack));
		var mf = MirBuild.synthetic(prep, abi, entryName(kind, k), tys, float ? F64 : I64, (b, ps) -> {
			var xs = [for (p in ps) p];
			xs.push(b.iconst(number));
			var r = b.call("hxmc_interp_pc$" + kind, Vector.fromArrayCopy(xs), float ? F64 : I64);
			b.f.vals[r].variadic = CallConv.ALL_REGS;
			b.ret(r);
		});
		mf.allRegs = true;
		return mf;
	}

	// the host's thread-local variables' accessors (hxmc_tls_get$<name>() and hxmc_tls_set$<name>(v))
	public static function tlsAccessors(prep:Prep, abi:Abi, names:Array<String>, compile:MFunc->Void) {
		for (n in names) {
			compile(MirBuild.synthetic(prep, abi, TLS_GET + n, vector(), I64, (b, _) -> b.ret(b.tlsLoad(n))));
			compile(MirBuild.synthetic(prep, abi, TLS_SET + n, vector(I64), I64, (b, ps) -> {
				b.tlsStore(n, ps[0]);
				b.ret(b.lconst(0, 0));
			}));
		}
	}
}
