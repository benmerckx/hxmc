package hxmc;

import core.TType.TClass;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;
import hxmc.ir.CInterop;
import hxmc.ir.CInterop.CTy;
import hxmc.ir.CInterop.CSig;

// a register-sized part of a struct: its bytes (off, size) and whether a
// float register carries them
typedef CPart = {off:Int, size:Int, float:Bool};

// how a C call passes a struct argument
enum CPass {
	// in registers, all of them or none: when too few are left, the parts go
	// on the stack as the struct's memory (8-byte words; Apple: by size)
	PRegs(parts:Vector<CPart>);
	// on the stack, as the struct's memory in 8-byte words (System V's MEMORY class)
	PStack(parts:Vector<CPart>);
	// the address of a copy in the caller's frame
	PCopy;
	// one scalar argument of the struct's only field (WebAssembly)
	PScalar(off:Int, ty:CTy);
}

// how a C function returns a struct
enum CRet {
	// in registers: integer parts in the first two integer result registers,
	// float ones in the first float result registers, in order
	RRegs(parts:Vector<CPart>);
	// stored by the callee at an address the caller passes (arm64: x8; x86-64
	// and WebAssembly: a first argument)
	RSret;
	// the struct's only field, as a scalar result (WebAssembly)
	RScalar(off:Int, ty:CTy);
}

// Structs by value in C calls, one place per ABI (docs/plans/lowlevel.md, "Calls
// and linking"); MirBuild applies it to calls of C functions and to the
// entries of @:hxmc.callback functions, the instruction selections place the
// parts (MIns.cGroups, MIns.cRet, MFunc.cParams, MFunc.cRet).
// - AAPCS64 (Linux, macOS and Windows on arm64): a homogeneous aggregate of
//   one to four floats or doubles in float registers, another struct of up
//   to 16 bytes in one or two integer registers, a larger one as the address
//   of a copy (an argument) or of the caller's memory (a result, x8).
// - System V x86-64 (Linux, macOS): each eightbyte of a struct of up to 16
//   bytes is SSE (only floats and doubles) or INTEGER, and travels in the
//   next register of its class; a larger struct is MEMORY: copied onto the
//   stack (an argument), stored through a hidden first argument (a result).
// - Win64: a struct of 1, 2, 4 or 8 bytes in an integer register, another
//   as the address of a copy (an argument) or through a hidden first
//   argument (a result).
// - wasm32 (clang's C ABI): a struct of one scalar as that scalar, another
//   as the address of a copy (an argument) or through a hidden first
//   argument (a result).
class CAbi {
	// 8 or 4: the struct is a homogeneous aggregate of doubles or floats; 0: not one
	public static function hfa(c:TClass):Int {
		var fs = CInterop.scalars(c, 0);
		if (fs.length == 0 || fs.length > 4) return 0;
		var t = fs[0].ty;
		if (t != CF64 && t != CF32) return 0;
		for (x in fs)
			if (x.ty != t) return 0;
		return t == CF64 ? 8 : 4;
	}

	// AAPCS64: the parts of a struct that travels in registers, or null
	static function a64Parts(c:TClass):Null<Vector<CPart>> {
		var h = hfa(c);
		if (h != 0) {
			var fs = CInterop.scalars(c, 0);
			var ps = new Vector<CPart>(fs.length);
			for (k in 0...fs.length)
				ps[k] = {off: fs[k].off, size: h, float: true};
			return ps;
		}
		var size = CInterop.layout(c).size;
		return size <= 16 ? words(size, _ -> false) : null;
	}

	// System V: the eightbytes of a struct of up to 16 bytes, SSE when every
	// scalar in it is a float or a double; null: MEMORY
	static function sysvParts(c:TClass):Null<Vector<CPart>> {
		var size = CInterop.layout(c).size;
		if (size > 16) return null;
		var fs = CInterop.scalars(c, 0);
		return words(size, at -> {
			var sse = true;
			for (f in fs)
				if (f.off >= at && f.off < at + 8 && f.ty != CF32 && f.ty != CF64) sse = false;
			sse;
		});
	}

	// the struct's bytes in 8-byte words (the last one shorter)
	static function words(size:Int, float:Int->Bool):Vector<CPart> {
		var ps = new Vector<CPart>((size + 7) >> 3);
		for (k in 0...ps.length)
			ps[k] = {off: 8 * k, size: size - 8 * k < 8 ? size - 8 * k : 8, float: float(8 * k)};
		return ps;
	}

	// wasm32: the type of the only scalar of a struct, or null
	static function single(c:TClass):Null<{off:Int, ty:CTy}> {
		var fs = CInterop.scalars(c, 0);
		return fs.length == 1 ? fs[0] : null;
	}

	public static function arg(abi:Abi, c:TClass):CPass {
		if (abi.wasm) {
			var s = single(c);
			return s != null ? PScalar(s.off, s.ty) : PCopy;
		}
		if (abi.arm) {
			var ps = a64Parts(c);
			return ps != null ? PRegs(ps) : PCopy;
		}
		var size = CInterop.layout(c).size;
		if (abi.os == "windows") return size == 1 || size == 2 || size == 4 || size == 8 ? PRegs(vector({off: 0, size: size, float: false})) : PCopy;
		var ps = sysvParts(c);
		return ps != null ? PRegs(ps) : PStack(words(size, _ -> false));
	}

	public static function ret(abi:Abi, c:TClass):CRet {
		if (abi.wasm) {
			var s = single(c);
			return s != null ? RScalar(s.off, s.ty) : RSret;
		}
		var ps = if (abi.arm) a64Parts(c) else if (abi.os == "windows") {
			var size = CInterop.layout(c).size;
			size == 1 || size == 2 || size == 4 || size == 8 ? vector({off: 0, size: size, float: false}) : null;
		} else sysvParts(c);
		return ps != null ? RRegs(ps) : RSret;
	}

	// wasm32: the signature of a C function as the module imports it, a
	// struct argument being its scalar or an address, a struct result its
	// scalar or a first argument (the address it is stored at)
	public static function wasmSig(sig:CSig):CSig {
		var args = [];
		var ret = sig.ret;
		switch ret {
			case CStruct(c):
				var s = single(c);
				if (s != null) ret = s.ty else {
					args.push(CPtr);
					ret = CVoid;
				}
			case _:
		}
		for (a in sig.args)
			args.push(switch a {
				case CStruct(c):
					var s = single(c);
					s != null ? s.ty : CPtr;
				case _: a;
			});
		return {args: args, ret: ret};
	}
}
