package hxmc.simd;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

// The vector types' operations (docs/plans/simd.md), each a WebAssembly
// SIMD instruction by name: on hxmc's native and WebAssembly targets the
// compiler's intrinsic (Simd, expanded inline), elsewhere (the Mir
// interpreter, Eval, JavaScript, ...) the same operation lane by lane (Ref,
// by opcode, with the same results). Lanes and constants' words are
// literals.
@:noCompletion class Ops {
	#if macro
	// (hxmc.SimdOps' names and opcodes)
	static final CODES:Map<String, Int> = [
		"v128.load" => 0x00,
		"v128.store" => 0x0b,
		"i8x16.shuffle" => 0x0d,
		"i8x16.swizzle" => 0x0e,
		"i8x16.splat" => 0x0f,
		"i16x8.splat" => 0x10,
		"i32x4.splat" => 0x11,
		"i64x2.splat" => 0x12,
		"f32x4.splat" => 0x13,
		"f64x2.splat" => 0x14,
		"i8x16.extract_lane_s" => 0x15,
		"i8x16.extract_lane_u" => 0x16,
		"i8x16.replace_lane" => 0x17,
		"i16x8.extract_lane_s" => 0x18,
		"i16x8.extract_lane_u" => 0x19,
		"i16x8.replace_lane" => 0x1a,
		"i32x4.extract_lane" => 0x1b,
		"i32x4.replace_lane" => 0x1c,
		"i64x2.extract_lane" => 0x1d,
		"i64x2.replace_lane" => 0x1e,
		"f32x4.extract_lane" => 0x1f,
		"f32x4.replace_lane" => 0x20,
		"f64x2.extract_lane" => 0x21,
		"f64x2.replace_lane" => 0x22,
		"i8x16.eq" => 0x23,
		"i8x16.ne" => 0x24,
		"i8x16.lt_s" => 0x25,
		"i8x16.lt_u" => 0x26,
		"i8x16.gt_s" => 0x27,
		"i8x16.gt_u" => 0x28,
		"i8x16.le_s" => 0x29,
		"i8x16.le_u" => 0x2a,
		"i8x16.ge_s" => 0x2b,
		"i8x16.ge_u" => 0x2c,
		"i16x8.eq" => 0x2d,
		"i16x8.ne" => 0x2e,
		"i16x8.lt_s" => 0x2f,
		"i16x8.lt_u" => 0x30,
		"i16x8.gt_s" => 0x31,
		"i16x8.gt_u" => 0x32,
		"i16x8.le_s" => 0x33,
		"i16x8.le_u" => 0x34,
		"i16x8.ge_s" => 0x35,
		"i16x8.ge_u" => 0x36,
		"i32x4.eq" => 0x37,
		"i32x4.ne" => 0x38,
		"i32x4.lt_s" => 0x39,
		"i32x4.lt_u" => 0x3a,
		"i32x4.gt_s" => 0x3b,
		"i32x4.gt_u" => 0x3c,
		"i32x4.le_s" => 0x3d,
		"i32x4.le_u" => 0x3e,
		"i32x4.ge_s" => 0x3f,
		"i32x4.ge_u" => 0x40,
		"f32x4.eq" => 0x41,
		"f32x4.ne" => 0x42,
		"f32x4.lt" => 0x43,
		"f32x4.gt" => 0x44,
		"f32x4.le" => 0x45,
		"f32x4.ge" => 0x46,
		"f64x2.eq" => 0x47,
		"f64x2.ne" => 0x48,
		"f64x2.lt" => 0x49,
		"f64x2.gt" => 0x4a,
		"f64x2.le" => 0x4b,
		"f64x2.ge" => 0x4c,
		"v128.not" => 0x4d,
		"v128.and" => 0x4e,
		"v128.andnot" => 0x4f,
		"v128.or" => 0x50,
		"v128.xor" => 0x51,
		"v128.bitselect" => 0x52,
		"v128.any_true" => 0x53,
		"v128.store32_lane" => 0x5a,
		"v128.store64_lane" => 0x5b,
		"v128.load32_zero" => 0x5c,
		"v128.load64_zero" => 0x5d,
		"f32x4.demote_f64x2_zero" => 0x5e,
		"f64x2.promote_low_f32x4" => 0x5f,
		"i8x16.abs" => 0x60,
		"i8x16.neg" => 0x61,
		"i8x16.all_true" => 0x63,
		"i8x16.bitmask" => 0x64,
		"i8x16.narrow_i16x8_s" => 0x65,
		"i8x16.narrow_i16x8_u" => 0x66,
		"f32x4.ceil" => 0x67,
		"f32x4.floor" => 0x68,
		"f32x4.trunc" => 0x69,
		"f32x4.nearest" => 0x6a,
		"i8x16.shl" => 0x6b,
		"i8x16.shr_s" => 0x6c,
		"i8x16.shr_u" => 0x6d,
		"i8x16.add" => 0x6e,
		"i8x16.add_sat_s" => 0x6f,
		"i8x16.add_sat_u" => 0x70,
		"i8x16.sub" => 0x71,
		"i8x16.sub_sat_s" => 0x72,
		"i8x16.sub_sat_u" => 0x73,
		"f64x2.ceil" => 0x74,
		"f64x2.floor" => 0x75,
		"i8x16.min_s" => 0x76,
		"i8x16.min_u" => 0x77,
		"i8x16.max_s" => 0x78,
		"i8x16.max_u" => 0x79,
		"f64x2.trunc" => 0x7a,
		"i8x16.avgr_u" => 0x7b,
		"i16x8.abs" => 0x80,
		"i16x8.neg" => 0x81,
		"i16x8.q15mulr_sat_s" => 0x82,
		"i16x8.all_true" => 0x83,
		"i16x8.bitmask" => 0x84,
		"i16x8.narrow_i32x4_s" => 0x85,
		"i16x8.narrow_i32x4_u" => 0x86,
		"i16x8.extend_low_i8x16_s" => 0x87,
		"i16x8.extend_high_i8x16_s" => 0x88,
		"i16x8.extend_low_i8x16_u" => 0x89,
		"i16x8.extend_high_i8x16_u" => 0x8a,
		"i16x8.shl" => 0x8b,
		"i16x8.shr_s" => 0x8c,
		"i16x8.shr_u" => 0x8d,
		"i16x8.add" => 0x8e,
		"i16x8.add_sat_s" => 0x8f,
		"i16x8.add_sat_u" => 0x90,
		"i16x8.sub" => 0x91,
		"i16x8.sub_sat_s" => 0x92,
		"i16x8.sub_sat_u" => 0x93,
		"f64x2.nearest" => 0x94,
		"i16x8.mul" => 0x95,
		"i16x8.min_s" => 0x96,
		"i16x8.min_u" => 0x97,
		"i16x8.max_s" => 0x98,
		"i16x8.max_u" => 0x99,
		"i16x8.avgr_u" => 0x9b,
		"i32x4.abs" => 0xa0,
		"i32x4.neg" => 0xa1,
		"i32x4.all_true" => 0xa3,
		"i32x4.bitmask" => 0xa4,
		"i32x4.extend_low_i16x8_s" => 0xa7,
		"i32x4.extend_high_i16x8_s" => 0xa8,
		"i32x4.extend_low_i16x8_u" => 0xa9,
		"i32x4.extend_high_i16x8_u" => 0xaa,
		"i32x4.shl" => 0xab,
		"i32x4.shr_s" => 0xac,
		"i32x4.shr_u" => 0xad,
		"i32x4.add" => 0xae,
		"i32x4.sub" => 0xb1,
		"i32x4.mul" => 0xb5,
		"i32x4.min_s" => 0xb6,
		"i32x4.min_u" => 0xb7,
		"i32x4.max_s" => 0xb8,
		"i32x4.max_u" => 0xb9,
		"i32x4.dot_i16x8_s" => 0xba,
		"i64x2.neg" => 0xc1,
		"i64x2.all_true" => 0xc3,
		"i64x2.bitmask" => 0xc4,
		"i64x2.extend_low_i32x4_s" => 0xc7,
		"i64x2.extend_high_i32x4_s" => 0xc8,
		"i64x2.extend_low_i32x4_u" => 0xc9,
		"i64x2.extend_high_i32x4_u" => 0xca,
		"i64x2.shl" => 0xcb,
		"i64x2.shr_s" => 0xcc,
		"i64x2.shr_u" => 0xcd,
		"i64x2.add" => 0xce,
		"i64x2.sub" => 0xd1,
		"i64x2.eq" => 0xd6,
		"i64x2.ne" => 0xd7,
		"f32x4.abs" => 0xe0,
		"f32x4.neg" => 0xe1,
		"f32x4.sqrt" => 0xe3,
		"f32x4.add" => 0xe4,
		"f32x4.sub" => 0xe5,
		"f32x4.mul" => 0xe6,
		"f32x4.div" => 0xe7,
		"f32x4.min" => 0xe8,
		"f32x4.max" => 0xe9,
		"f32x4.pmin" => 0xea,
		"f32x4.pmax" => 0xeb,
		"f64x2.abs" => 0xec,
		"f64x2.neg" => 0xed,
		"f64x2.sqrt" => 0xef,
		"f64x2.add" => 0xf0,
		"f64x2.sub" => 0xf1,
		"f64x2.mul" => 0xf2,
		"f64x2.div" => 0xf3,
		"f64x2.min" => 0xf4,
		"f64x2.max" => 0xf5,
		"f64x2.pmin" => 0xf6,
		"f64x2.pmax" => 0xf7,
		"i32x4.trunc_sat_f32x4_s" => 0xf8,
		"f32x4.convert_i32x4_s" => 0xfa,
		"f32x4.convert_i32x4_u" => 0xfb,
		"i32x4.trunc_sat_f64x2_s_zero" => 0xfc,
		"f64x2.convert_low_i32x4_s" => 0xfe
	];

	static function native():Bool
		return Context.definedValue("target.name") == "hxmc" && !Context.defined("hxmc.interp");

	static function code(op:Expr):Expr {
		var n = switch op.expr {
			case EConst(CString(s, _)): s;
			case _: Context.error("hxmc.simd: the operation must be a literal", op.pos);
		};
		if (!CODES.exists(n)) Context.error("hxmc.simd: no operation " + n, op.pos);
		return macro $v{CODES.get(n)};
	}

	static function call(fn:String, op:Null<Expr>, args:Array<Expr>):Expr {
		if (native()) return macro hxmc.simd.Simd.$fn($a{op == null ? args : [op].concat(args)});
		if (fn == "load" || fn == "store") return macro hxmc.simd.RefMem.$fn($a{[code(op)].concat(args)});
		return macro hxmc.simd.Ref.$fn($a{op == null ? args : [code(op)].concat(args)});
	}
	#end

	public static macro function op1(op:Expr, a:Expr):Expr
		return call("op1", op, [a]);

	public static macro function op2(op:Expr, a:Expr, b:Expr):Expr
		return call("op2", op, [a, b]);

	public static macro function op3(op:Expr, a:Expr, b:Expr, c:Expr):Expr
		return call("op3", op, [a, b, c]);

	public static macro function shift(op:Expr, a:Expr, n:Expr):Expr
		return call("shift", op, [a, n]);

	public static macro function splatInt(op:Expr, x:Expr):Expr
		return call("splatInt", op, [x]);

	public static macro function splatI64(op:Expr, x:Expr):Expr
		return call("splatI64", op, [x]);

	public static macro function splatFloat(op:Expr, x:Expr):Expr
		return call("splatFloat", op, [x]);

	public static macro function extractInt(op:Expr, a:Expr, lane:Expr):Expr
		return call("extractInt", op, [a, lane]);

	public static macro function extractI64(op:Expr, a:Expr, lane:Expr):Expr
		return call("extractI64", op, [a, lane]);

	public static macro function extractFloat(op:Expr, a:Expr, lane:Expr):Expr
		return call("extractFloat", op, [a, lane]);

	public static macro function replaceInt(op:Expr, a:Expr, lane:Expr, x:Expr):Expr
		return call("replaceInt", op, [a, lane, x]);

	public static macro function replaceI64(op:Expr, a:Expr, lane:Expr, x:Expr):Expr
		return call("replaceI64", op, [a, lane, x]);

	public static macro function replaceFloat(op:Expr, a:Expr, lane:Expr, x:Expr):Expr
		return call("replaceFloat", op, [a, lane, x]);

	public static macro function test(op:Expr, a:Expr):Expr
		return call("test", op, [a]);

	public static macro function shuffle(a:Expr, b:Expr, lanes:Array<Expr>):Expr
		return call("shuffle", null, [a, b].concat(lanes));

	public static macro function const(w0:Expr, w1:Expr, w2:Expr, w3:Expr):Expr
		return call("const", null, [w0, w1, w2, w3]);

	// raw memory at p + off (hxmc only)
	public static macro function load(op:Expr, p:Expr, off:Expr):Expr
		return call("load", op, [p, off]);

	public static macro function store(op:Expr, p:Expr, off:Expr, v:Expr):Expr
		return call("store", op, [p, off, v]);
}
