package hxmc.simd;

// Sixteen unsigned 8-bit lanes (docs/plans/simd.md): a value (16 bytes, in a vector register on hxmc),
// never null, copied on assignment. Lane arithmetic wraps unless named
// saturating; lane indices are constants; comparisons give masks (I8x16: all
// ones where true).
abstract U8x16(V128) {
	inline function new(v:V128)
		this = v;

	@:to inline function bits():V128
		return this;

	// x in every lane (its low bits)
	public static inline function splat(x:Int):U8x16
		return new U8x16(Ops.splatInt("i8x16.splat", x));

	public static inline function zero():U8x16
		return new U8x16(Ops.const(0, 0, 0, 0));

	// lane i (a constant)
	public inline function get(i:Int):Int
		return Ops.extractInt("i8x16.extract_lane_u", this, i);

	// this with lane i (a constant) x
	public inline function with(i:Int, x:Int):U8x16
		return new U8x16(Ops.replaceInt("i8x16.replace_lane", this, i, x));

	@:op(A + B) inline function add(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.add", this, b));

	@:op(A - B) inline function sub(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.sub", this, b));

	@:op(A & B) inline function and(b:U8x16):U8x16
		return new U8x16(Ops.op2("v128.and", this, b));

	@:op(A | B) inline function or(b:U8x16):U8x16
		return new U8x16(Ops.op2("v128.or", this, b));

	@:op(A ^ B) inline function xor(b:U8x16):U8x16
		return new U8x16(Ops.op2("v128.xor", this, b));

	@:op(~A) inline function not():U8x16
		return new U8x16(Ops.op1("v128.not", this));

	// this & ~b
	public inline function andNot(b:U8x16):U8x16
		return new U8x16(Ops.op2("v128.andnot", this, b));

	// shifts by n modulo the lane's width
	@:op(A << B) inline function shl(n:Int):U8x16
		return new U8x16(Ops.shift("i8x16.shl", this, n));

	@:op(A >> B) inline function shr(n:Int):U8x16
		return new U8x16(Ops.shift("i8x16.shr_u", this, n));

	@:op(A >>> B) inline function ushr(n:Int):U8x16
		return new U8x16(Ops.shift("i8x16.shr_u", this, n));

	public inline function eq(b:U8x16):I8x16
		return cast Ops.op2("i8x16.eq", this, b);

	public inline function ne(b:U8x16):I8x16
		return cast Ops.op2("i8x16.ne", this, b);

	// a's lanes where mask's bits are set, else b's (bitwise)
	public static inline function select(mask:I8x16, a:U8x16, b:U8x16):U8x16
		return new U8x16(Ops.op3("v128.bitselect", a, b, mask));

	// whether any bit is set
	public inline function any():Bool
		return Ops.test("v128.any_true", this) != 0;

	// whether no lane is zero
	public inline function all():Bool
		return Ops.test("i8x16.all_true", this) != 0;

	// the lanes' top bits, lane 0 lowest
	public inline function bitmask():Int
		return Ops.test("i8x16.bitmask", this);

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

	public static inline function load(b:haxe.io.Bytes, pos:Int):U8x16
		return new U8x16(Mem128.loadBytes(b, pos));

	public inline function store(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes(b, pos, this);

	public static inline function loadSpan(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U8x16
		return new U8x16(Mem128.loadSpan(s, pos));

	public inline function storeSpan(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan(s, pos, this);

	// the low 8 (4) bytes: loaded, the rest zero; stored, the rest left
	public static inline function load64(b:haxe.io.Bytes, pos:Int):U8x16
		return new U8x16(Mem128.loadBytes64(b, pos));

	public static inline function load32(b:haxe.io.Bytes, pos:Int):U8x16
		return new U8x16(Mem128.loadBytes32(b, pos));

	public inline function store64(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes64(b, pos, this);

	public inline function store32(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes32(b, pos, this);

	public static inline function loadSpan64(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U8x16
		return new U8x16(Mem128.loadSpan64(s, pos));

	public static inline function loadSpan32(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U8x16
		return new U8x16(Mem128.loadSpan32(s, pos));

	public inline function storeSpan64(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan64(s, pos, this);

	public inline function storeSpan32(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan32(s, pos, this);

	#if (target.name == "hxmc")
	public static inline function loadPtr(p:hxmc.unsafe.Ptr, off:Int):U8x16
		return new U8x16(Ops.load("v128.load", p, off));

	public inline function storePtr(p:hxmc.unsafe.Ptr, off:Int):Void
		Ops.store("v128.store", p, off, this);
	#end

	public inline function min(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.min_u", this, b));

	public inline function max(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.max_u", this, b));

	public inline function lt(b:U8x16):I8x16
		return cast Ops.op2("i8x16.lt_u", this, b);

	public inline function le(b:U8x16):I8x16
		return cast Ops.op2("i8x16.le_u", this, b);

	public inline function gt(b:U8x16):I8x16
		return cast Ops.op2("i8x16.gt_u", this, b);

	public inline function ge(b:U8x16):I8x16
		return cast Ops.op2("i8x16.ge_u", this, b);

	// this clamped to [lo, hi]
	public inline function clamp(lo:U8x16, hi:U8x16):U8x16
		return max(lo).min(hi);

	// lanes of this (0-15) and b (16-31), constants
	public inline function shuffle(b:U8x16, i0:Int, i1:Int, i2:Int, i3:Int, i4:Int, i5:Int, i6:Int, i7:Int, i8:Int, i9:Int, i10:Int, i11:Int, i12:Int,
			i13:Int, i14:Int, i15:Int):U8x16
		return new U8x16(Ops.shuffle(this, b, i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15));

	public static inline function make(a0:Int, a1:Int, a2:Int, a3:Int, a4:Int, a5:Int, a6:Int, a7:Int, a8:Int, a9:Int, a10:Int, a11:Int, a12:Int,
			a13:Int, a14:Int, a15:Int):U8x16
		return splat(a0).with(1, a1).with(2, a2).with(3, a3).with(4, a4).with(5, a5).with(6, a6).with(7, a7).with(8, a8).with(9, a9).with(10, a10)
			.with(11, a11).with(12, a12).with(13, a13).with(14, a14).with(15, a15);

	public inline function toString():String
		return '(${get(0)}, ${get(1)}, ${get(2)}, ${get(3)}, ${get(4)}, ${get(5)}, ${get(6)}, ${get(7)}, ${get(8)}, ${get(9)}, ${get(10)}, ${get(11)}, ${get(12)}, ${get(13)}, ${get(14)}, ${get(15)})';

	public inline function addSat(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.add_sat_u", this, b));

	public inline function subSat(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.sub_sat_u", this, b));

	public inline function avg(b:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.avgr_u", this, b));

	// this's lanes at the indices of idx (run time; from 16 on: 0)
	public inline function swizzle(idx:U8x16):U8x16
		return new U8x16(Ops.op2("i8x16.swizzle", this, idx));

	// a's lanes then b's (signed), saturated to 0..255
	public static inline function narrow(a:I16x8, b:I16x8):U8x16
		return new U8x16(Ops.op2("i8x16.narrow_i16x8_u", a, b));
}
