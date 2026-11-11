package hxmc.simd;

// Eight unsigned 16-bit lanes (docs/plans/simd.md): a value (16 bytes, in a vector register on hxmc),
// never null, copied on assignment. Lane arithmetic wraps unless named
// saturating; lane indices are constants; comparisons give masks (I16x8: all
// ones where true).
abstract U16x8(V128) {
	inline function new(v:V128)
		this = v;

	@:to inline function bits():V128
		return this;

	// x in every lane (its low bits)
	public static inline function splat(x:Int):U16x8
		return new U16x8(Ops.splatInt("i16x8.splat", x));

	public static inline function zero():U16x8
		return new U16x8(Ops.const(0, 0, 0, 0));

	// lane i (a constant)
	public inline function get(i:Int):Int
		return Ops.extractInt("i16x8.extract_lane_u", this, i);

	// this with lane i (a constant) x
	public inline function with(i:Int, x:Int):U16x8
		return new U16x8(Ops.replaceInt("i16x8.replace_lane", this, i, x));

	@:op(A + B) inline function add(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.add", this, b));

	@:op(A - B) inline function sub(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.sub", this, b));

	@:op(A & B) inline function and(b:U16x8):U16x8
		return new U16x8(Ops.op2("v128.and", this, b));

	@:op(A | B) inline function or(b:U16x8):U16x8
		return new U16x8(Ops.op2("v128.or", this, b));

	@:op(A ^ B) inline function xor(b:U16x8):U16x8
		return new U16x8(Ops.op2("v128.xor", this, b));

	@:op(~A) inline function not():U16x8
		return new U16x8(Ops.op1("v128.not", this));

	// this & ~b
	public inline function andNot(b:U16x8):U16x8
		return new U16x8(Ops.op2("v128.andnot", this, b));

	// shifts by n modulo the lane's width
	@:op(A << B) inline function shl(n:Int):U16x8
		return new U16x8(Ops.shift("i16x8.shl", this, n));

	@:op(A >> B) inline function shr(n:Int):U16x8
		return new U16x8(Ops.shift("i16x8.shr_u", this, n));

	@:op(A >>> B) inline function ushr(n:Int):U16x8
		return new U16x8(Ops.shift("i16x8.shr_u", this, n));

	public inline function eq(b:U16x8):I16x8
		return cast Ops.op2("i16x8.eq", this, b);

	public inline function ne(b:U16x8):I16x8
		return cast Ops.op2("i16x8.ne", this, b);

	// a's lanes where mask's bits are set, else b's (bitwise)
	public static inline function select(mask:I16x8, a:U16x8, b:U16x8):U16x8
		return new U16x8(Ops.op3("v128.bitselect", a, b, mask));

	// whether any bit is set
	public inline function any():Bool
		return Ops.test("v128.any_true", this) != 0;

	// whether no lane is zero
	public inline function all():Bool
		return Ops.test("i16x8.all_true", this) != 0;

	// the lanes' top bits, lane 0 lowest
	public inline function bitmask():Int
		return Ops.test("i16x8.bitmask", this);

	public inline function asF32x4():F32x4
		return cast this;

	public inline function asF64x2():F64x2
		return cast this;

	public inline function asI8x16():I8x16
		return cast this;

	public inline function asU8x16():U8x16
		return cast this;

	public inline function asI16x8():I16x8
		return cast this;

	public inline function asU16x8():U16x8
		return cast this;

	public inline function asI32x4():I32x4
		return cast this;

	public inline function asU32x4():U32x4
		return cast this;

	public inline function asI64x2():I64x2
		return cast this;

	// ---- memory: 16 bytes, unaligned, little-endian

	public static inline function load(b:haxe.io.Bytes, pos:Int):U16x8
		return new U16x8(Mem128.loadBytes(b, pos));

	public inline function store(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes(b, pos, this);

	public static inline function loadSpan(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U16x8
		return new U16x8(Mem128.loadSpan(s, pos));

	public inline function storeSpan(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan(s, pos, this);

	// the low 8 (4) bytes: loaded, the rest zero; stored, the rest left
	public static inline function load64(b:haxe.io.Bytes, pos:Int):U16x8
		return new U16x8(Mem128.loadBytes64(b, pos));

	public static inline function load32(b:haxe.io.Bytes, pos:Int):U16x8
		return new U16x8(Mem128.loadBytes32(b, pos));

	public inline function store64(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes64(b, pos, this);

	public inline function store32(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes32(b, pos, this);

	public static inline function loadSpan64(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U16x8
		return new U16x8(Mem128.loadSpan64(s, pos));

	public static inline function loadSpan32(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U16x8
		return new U16x8(Mem128.loadSpan32(s, pos));

	public inline function storeSpan64(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan64(s, pos, this);

	public inline function storeSpan32(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan32(s, pos, this);

	#if (target.name == "hxmc")
	@:hxmc.unsafe(gc) public static inline function loadPtr(p:hxmc.unsafe.Ptr, off:Int):U16x8
		return new U16x8(Ops.load("v128.load", p, off));

	@:hxmc.unsafe(gc) public inline function storePtr(p:hxmc.unsafe.Ptr, off:Int):Void
		Ops.store("v128.store", p, off, this);
	#end

	public inline function min(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.min_u", this, b));

	public inline function max(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.max_u", this, b));

	public inline function lt(b:U16x8):I16x8
		return cast Ops.op2("i16x8.lt_u", this, b);

	public inline function le(b:U16x8):I16x8
		return cast Ops.op2("i16x8.le_u", this, b);

	public inline function gt(b:U16x8):I16x8
		return cast Ops.op2("i16x8.gt_u", this, b);

	public inline function ge(b:U16x8):I16x8
		return cast Ops.op2("i16x8.ge_u", this, b);

	// this clamped to [lo, hi]
	public inline function clamp(lo:U16x8, hi:U16x8):U16x8
		return max(lo).min(hi);

	// lanes of this (0-7) and b (8-15), constants
	public inline function shuffle(b:U16x8, i0:Int, i1:Int, i2:Int, i3:Int, i4:Int, i5:Int, i6:Int, i7:Int):U16x8
		return new U16x8(Ops.shuffle(this, b, i0 * 2, i0 * 2 + 1, i1 * 2, i1 * 2 + 1, i2 * 2, i2 * 2 + 1, i3 * 2, i3 * 2 + 1, i4 * 2, i4 * 2 + 1, i5 * 2,
			i5 * 2 + 1, i6 * 2, i6 * 2 + 1, i7 * 2, i7 * 2 + 1));

	public inline function swizzle(i0:Int, i1:Int, i2:Int, i3:Int, i4:Int, i5:Int, i6:Int, i7:Int):U16x8
		return shuffle(new U16x8(this), i0, i1, i2, i3, i4, i5, i6, i7);

	@:op(A * B) inline function mul(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.mul", this, b));

	public static inline function make(a0:Int, a1:Int, a2:Int, a3:Int, a4:Int, a5:Int, a6:Int, a7:Int):U16x8
		return splat(a0).with(1, a1).with(2, a2).with(3, a3).with(4, a4).with(5, a5).with(6, a6).with(7, a7);

	public inline function toString():String
		return '(${get(0)}, ${get(1)}, ${get(2)}, ${get(3)}, ${get(4)}, ${get(5)}, ${get(6)}, ${get(7)})';

	public inline function addSat(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.add_sat_u", this, b));

	public inline function subSat(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.sub_sat_u", this, b));

	// (this + b + 1) >> 1
	public inline function avg(b:U16x8):U16x8
		return new U16x8(Ops.op2("i16x8.avgr_u", this, b));

	public static inline function extendLow(v:U8x16):U16x8
		return new U16x8(Ops.op1("i16x8.extend_low_i8x16_u", v));

	public static inline function extendHigh(v:U8x16):U16x8
		return new U16x8(Ops.op1("i16x8.extend_high_i8x16_u", v));

	// a's lanes then b's (signed), saturated to 0..65535
	public static inline function narrow(a:I32x4, b:I32x4):U16x8
		return new U16x8(Ops.op2("i16x8.narrow_i32x4_u", a, b));
}
