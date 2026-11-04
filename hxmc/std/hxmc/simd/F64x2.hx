package hxmc.simd;

import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// Two float64 lanes (docs/plans/simd.md): a value (16 bytes, in a vector
// register on hxmc), never null, copied on assignment. NaN results have no
// specified sign or payload. Lane indices are constants. Comparisons give
// masks (I64x2: all ones where true).
abstract F64x2(V128) {
	inline function new(v:V128)
		this = v;

	@:to inline function bits():V128
		return this;

	public static inline function splat(x:Float):F64x2
		return new F64x2(Ops.splatFloat("f64x2.splat", x));

	public static inline function make(a:Float, b:Float):F64x2
		return splat(a).with(1, b);

	public static inline function zero():F64x2
		return new F64x2(Ops.const(0, 0, 0, 0));

	public inline function get(i:Int):Float
		return Ops.extractFloat("f64x2.extract_lane", this, i);

	public inline function with(i:Int, x:Float):F64x2
		return new F64x2(Ops.replaceFloat("f64x2.replace_lane", this, i, x));

	@:op(A + B) inline function add(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.add", this, b));

	@:op(A - B) inline function sub(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.sub", this, b));

	@:op(A * B) inline function mul(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.mul", this, b));

	@:op(A / B) inline function div(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.div", this, b));

	@:op(-A) inline function neg():F64x2
		return new F64x2(Ops.op1("f64x2.neg", this));

	// this * b + c, rounded twice (no fused multiply-add)
	public inline function mulAdd(b:F64x2, c:F64x2):F64x2
		return mul(b).add(c);

	public inline function min(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.min", this, b));

	public inline function max(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.max", this, b));

	public inline function pmin(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.pmin", this, b));

	public inline function pmax(b:F64x2):F64x2
		return new F64x2(Ops.op2("f64x2.pmax", this, b));

	public inline function abs():F64x2
		return new F64x2(Ops.op1("f64x2.abs", this));

	public inline function sqrt():F64x2
		return new F64x2(Ops.op1("f64x2.sqrt", this));

	public inline function floor():F64x2
		return new F64x2(Ops.op1("f64x2.floor", this));

	public inline function ceil():F64x2
		return new F64x2(Ops.op1("f64x2.ceil", this));

	public inline function trunc():F64x2
		return new F64x2(Ops.op1("f64x2.trunc", this));

	public inline function round():F64x2
		return new F64x2(Ops.op1("f64x2.nearest", this));

	public inline function clamp(lo:F64x2, hi:F64x2):F64x2
		return lo.pmax(new F64x2(this)).pmin(hi);

	public inline function eq(b:F64x2):I64x2
		return cast Ops.op2("f64x2.eq", this, b);

	public inline function ne(b:F64x2):I64x2
		return cast Ops.op2("f64x2.ne", this, b);

	public inline function lt(b:F64x2):I64x2
		return cast Ops.op2("f64x2.lt", this, b);

	public inline function le(b:F64x2):I64x2
		return cast Ops.op2("f64x2.le", this, b);

	public inline function gt(b:F64x2):I64x2
		return cast Ops.op2("f64x2.gt", this, b);

	public inline function ge(b:F64x2):I64x2
		return cast Ops.op2("f64x2.ge", this, b);

	public static inline function select(mask:I64x2, a:F64x2, b:F64x2):F64x2
		return new F64x2(Ops.op3("v128.bitselect", a, b, mask));

	// lanes of this (0-1) and b (2-3), constants
	public inline function shuffle(b:F64x2, i0:Int, i1:Int):F64x2
		return new F64x2(Ops.shuffle(this, b, i0 * 8, i0 * 8 + 1, i0 * 8 + 2, i0 * 8 + 3, i0 * 8 + 4, i0 * 8 + 5, i0 * 8 + 6, i0 * 8 + 7, i1 * 8,
			i1 * 8 + 1, i1 * 8 + 2, i1 * 8 + 3, i1 * 8 + 4, i1 * 8 + 5, i1 * 8 + 6, i1 * 8 + 7));

	// lane 0 + lane 1
	public inline function sum():Float
		return add(shuffle(new F64x2(this), 1, 0)).get(0);

	// lanes 0 and 1 of v (float32), exactly
	public static inline function promoteLow(v:F32x4):F64x2
		return new F64x2(Ops.op1("f64x2.promote_low_f32x4", v));

	// lanes 0 and 1 of v
	public static inline function fromI32x4Low(v:I32x4):F64x2
		return new F64x2(Ops.op1("f64x2.convert_low_i32x4_s", v));

	// truncated, saturating, NaN to 0: lanes 0 and 1 of the result (2 and 3 zero)
	public inline function toI32x4():I32x4
		return cast Ops.op1("i32x4.trunc_sat_f64x2_s_zero", this);

	public inline function asI64x2():I64x2
		return cast this;

	public inline function asU8x16():U8x16
		return cast this;

	public static inline function load(b:Bytes, pos:Int):F64x2
		return new F64x2(Mem128.loadBytes(b, pos));

	public inline function store(b:Bytes, pos:Int):Void
		Mem128.storeBytes(b, pos, this);

	public static inline function loadSpan(s:ReadOnlySpan<UInt8>, pos:Int):F64x2
		return new F64x2(Mem128.loadSpan(s, pos));

	public inline function storeSpan(s:Span<UInt8>, pos:Int):Void
		Mem128.storeSpan(s, pos, this);

	// the low 8 (4) bytes: loaded, the rest zero; stored, the rest left
	public static inline function load64(b:haxe.io.Bytes, pos:Int):F64x2
		return new F64x2(Mem128.loadBytes64(b, pos));

	public static inline function load32(b:haxe.io.Bytes, pos:Int):F64x2
		return new F64x2(Mem128.loadBytes32(b, pos));

	public inline function store64(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes64(b, pos, this);

	public inline function store32(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes32(b, pos, this);

	public static inline function loadSpan64(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):F64x2
		return new F64x2(Mem128.loadSpan64(s, pos));

	public static inline function loadSpan32(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):F64x2
		return new F64x2(Mem128.loadSpan32(s, pos));

	public inline function storeSpan64(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan64(s, pos, this);

	public inline function storeSpan32(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan32(s, pos, this);

	#if (target.name == "hxmc")
	public static inline function loadPtr(p:hxmc.unsafe.Ptr, off:Int):F64x2
		return new F64x2(Ops.load("v128.load", p, off));

	public inline function storePtr(p:hxmc.unsafe.Ptr, off:Int):Void
		Ops.store("v128.store", p, off, this);
	#end

	public inline function toString():String
		return '(${get(0)}, ${get(1)})';
}
