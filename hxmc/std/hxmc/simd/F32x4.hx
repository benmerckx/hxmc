package hxmc.simd;

import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// Four float32 lanes (docs/plans/simd.md): a value (16 bytes, in a vector
// register on hxmc), never null, copied on assignment. Each lane's result is
// rounded to float32 (to nearest even); a lane read is a Float. NaN
// results have no specified sign or payload. Lane indices are constants.
// Comparisons give masks (I32x4: all ones where true).
abstract F32x4(V128) {
	inline function new(v:V128)
		this = v;

	@:to inline function bits():V128
		return this;

	// x in every lane (rounded to float32)
	public static inline function splat(x:Float):F32x4
		return new F32x4(Ops.splatFloat("f32x4.splat", x));

	public static inline function make(a:Float, b:Float, c:Float, d:Float):F32x4
		return splat(a).with(1, b).with(2, c).with(3, d);

	public static inline function zero():F32x4
		return new F32x4(Ops.const(0, 0, 0, 0));

	// lane i (a constant), exactly
	public inline function get(i:Int):Float
		return Ops.extractFloat("f32x4.extract_lane", this, i);

	// this with lane i (a constant) x
	public inline function with(i:Int, x:Float):F32x4
		return new F32x4(Ops.replaceFloat("f32x4.replace_lane", this, i, x));

	@:op(A + B) inline function add(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.add", this, b));

	@:op(A - B) inline function sub(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.sub", this, b));

	@:op(A * B) inline function mul(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.mul", this, b));

	@:op(A / B) inline function div(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.div", this, b));

	@:op(-A) inline function neg():F32x4
		return new F32x4(Ops.op1("f32x4.neg", this));

	// this * b + c, rounded twice (no fused multiply-add: the same result everywhere)
	public inline function mulAdd(b:F32x4, c:F32x4):F32x4
		return mul(b).add(c);

	// NaN where either lane is NaN; -0 below +0
	public inline function min(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.min", this, b));

	public inline function max(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.max", this, b));

	// b < this ? b : this (a lane of NaN or a zero: this's), one instruction everywhere
	public inline function pmin(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.pmin", this, b));

	// this < b ? b : this
	public inline function pmax(b:F32x4):F32x4
		return new F32x4(Ops.op2("f32x4.pmax", this, b));

	public inline function abs():F32x4
		return new F32x4(Ops.op1("f32x4.abs", this));

	public inline function sqrt():F32x4
		return new F32x4(Ops.op1("f32x4.sqrt", this));

	public inline function floor():F32x4
		return new F32x4(Ops.op1("f32x4.floor", this));

	public inline function ceil():F32x4
		return new F32x4(Ops.op1("f32x4.ceil", this));

	public inline function trunc():F32x4
		return new F32x4(Ops.op1("f32x4.trunc", this));

	// to the nearest integer, a half to even
	public inline function round():F32x4
		return new F32x4(Ops.op1("f32x4.nearest", this));

	// this clamped to [lo, hi] (pmax, then pmin: a NaN lane is lo's)
	public inline function clamp(lo:F32x4, hi:F32x4):F32x4
		return lo.pmax(new F32x4(this)).pmin(hi);

	public inline function eq(b:F32x4):I32x4
		return cast Ops.op2("f32x4.eq", this, b);

	public inline function ne(b:F32x4):I32x4
		return cast Ops.op2("f32x4.ne", this, b);

	public inline function lt(b:F32x4):I32x4
		return cast Ops.op2("f32x4.lt", this, b);

	public inline function le(b:F32x4):I32x4
		return cast Ops.op2("f32x4.le", this, b);

	public inline function gt(b:F32x4):I32x4
		return cast Ops.op2("f32x4.gt", this, b);

	public inline function ge(b:F32x4):I32x4
		return cast Ops.op2("f32x4.ge", this, b);

	// a's lanes where mask's are set, else b's (bitwise)
	public static inline function select(mask:I32x4, a:F32x4, b:F32x4):F32x4
		return new F32x4(Ops.op3("v128.bitselect", a, b, mask));

	// lanes of this (0-3) and b (4-7), constants
	public inline function shuffle(b:F32x4, i0:Int, i1:Int, i2:Int, i3:Int):F32x4
		return new F32x4(Ops.shuffle(this, b, i0 * 4, i0 * 4 + 1, i0 * 4 + 2, i0 * 4 + 3, i1 * 4, i1 * 4 + 1, i1 * 4 + 2, i1 * 4 + 3, i2 * 4, i2 * 4 + 1,
			i2 * 4 + 2, i2 * 4 + 3, i3 * 4, i3 * 4 + 1, i3 * 4 + 2, i3 * 4 + 3));

	// lanes of this (0-3), constants
	public inline function swizzle(i0:Int, i1:Int, i2:Int, i3:Int):F32x4
		return shuffle(new F32x4(this), i0, i1, i2, i3);

	// (lane 0 + lane 1) + (lane 2 + lane 3), each sum rounded to float32
	public inline function sum():Float {
		var t = add(swizzle(1, 0, 3, 2));
		return t.add(t.swizzle(2, 3, 0, 1)).get(0);
	}

	// truncated to integers, saturating; NaN to 0
	public inline function toI32x4():I32x4
		return cast Ops.op1("i32x4.trunc_sat_f32x4_s", this);

	public static inline function fromI32x4(v:I32x4):F32x4
		return new F32x4(Ops.op1("f32x4.convert_i32x4_s", v));

	public static inline function fromU32x4(v:U32x4):F32x4
		return new F32x4(Ops.op1("f32x4.convert_i32x4_u", v));

	// lanes 0 and 1 to float32, lanes 2 and 3 zero
	public static inline function demote(v:F64x2):F32x4
		return new F32x4(Ops.op1("f32x4.demote_f64x2_zero", v));

	// the same bits
	public inline function asI32x4():I32x4
		return cast this;

	public inline function asU32x4():U32x4
		return cast this;

	public inline function asU8x16():U8x16
		return cast this;

	// ---- memory: 16 bytes, unaligned, little-endian

	// at pos of b (OutsideBounds unless 0 <= pos <= b.length - 16)
	public static inline function load(b:Bytes, pos:Int):F32x4
		return new F32x4(Mem128.loadBytes(b, pos));

	public inline function store(b:Bytes, pos:Int):Void
		Mem128.storeBytes(b, pos, this);

	// at byte pos of a span (a kernel's; checked)
	public static inline function loadSpan(s:ReadOnlySpan<UInt8>, pos:Int):F32x4
		return new F32x4(Mem128.loadSpan(s, pos));

	public inline function storeSpan(s:Span<UInt8>, pos:Int):Void
		Mem128.storeSpan(s, pos, this);

	// the low 8 (4) bytes: loaded, the rest zero; stored, the rest left
	public static inline function load64(b:haxe.io.Bytes, pos:Int):F32x4
		return new F32x4(Mem128.loadBytes64(b, pos));

	public static inline function load32(b:haxe.io.Bytes, pos:Int):F32x4
		return new F32x4(Mem128.loadBytes32(b, pos));

	public inline function store64(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes64(b, pos, this);

	public inline function store32(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes32(b, pos, this);

	public static inline function loadSpan64(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):F32x4
		return new F32x4(Mem128.loadSpan64(s, pos));

	public static inline function loadSpan32(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):F32x4
		return new F32x4(Mem128.loadSpan32(s, pos));

	public inline function storeSpan64(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan64(s, pos, this);

	public inline function storeSpan32(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan32(s, pos, this);

	#if (target.name == "hxmc")
	// at p + off (@:hxmc.unsafe: unchecked)
	@:hxmc.unsafe(gc) public static inline function loadPtr(p:hxmc.unsafe.Ptr, off:Int):F32x4
		return new F32x4(Ops.load("v128.load", p, off));

	@:hxmc.unsafe(gc) public inline function storePtr(p:hxmc.unsafe.Ptr, off:Int):Void
		Ops.store("v128.store", p, off, this);
	#end

	public inline function toString():String
		return '(${get(0)}, ${get(1)}, ${get(2)}, ${get(3)})';
}
