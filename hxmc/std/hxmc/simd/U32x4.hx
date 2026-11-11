package hxmc.simd;

// Four unsigned 32-bit lanes (lanes read as Int: their bits) (docs/plans/simd.md): a value (16 bytes, in a vector register on hxmc),
// never null, copied on assignment. Lane arithmetic wraps unless named
// saturating; lane indices are constants; comparisons give masks (I32x4: all
// ones where true).
abstract U32x4(V128) {
	inline function new(v:V128)
		this = v;

	@:to inline function bits():V128
		return this;

	// x in every lane (its low bits)
	public static inline function splat(x:Int):U32x4
		return new U32x4(Ops.splatInt("i32x4.splat", x));

	public static inline function zero():U32x4
		return new U32x4(Ops.const(0, 0, 0, 0));

	// lane i (a constant)
	public inline function get(i:Int):Int
		return Ops.extractInt("i32x4.extract_lane", this, i);

	// this with lane i (a constant) x
	public inline function with(i:Int, x:Int):U32x4
		return new U32x4(Ops.replaceInt("i32x4.replace_lane", this, i, x));

	@:op(A + B) inline function add(b:U32x4):U32x4
		return new U32x4(Ops.op2("i32x4.add", this, b));

	@:op(A - B) inline function sub(b:U32x4):U32x4
		return new U32x4(Ops.op2("i32x4.sub", this, b));

	@:op(A & B) inline function and(b:U32x4):U32x4
		return new U32x4(Ops.op2("v128.and", this, b));

	@:op(A | B) inline function or(b:U32x4):U32x4
		return new U32x4(Ops.op2("v128.or", this, b));

	@:op(A ^ B) inline function xor(b:U32x4):U32x4
		return new U32x4(Ops.op2("v128.xor", this, b));

	@:op(~A) inline function not():U32x4
		return new U32x4(Ops.op1("v128.not", this));

	// this & ~b
	public inline function andNot(b:U32x4):U32x4
		return new U32x4(Ops.op2("v128.andnot", this, b));

	// shifts by n modulo the lane's width
	@:op(A << B) inline function shl(n:Int):U32x4
		return new U32x4(Ops.shift("i32x4.shl", this, n));

	@:op(A >> B) inline function shr(n:Int):U32x4
		return new U32x4(Ops.shift("i32x4.shr_u", this, n));

	@:op(A >>> B) inline function ushr(n:Int):U32x4
		return new U32x4(Ops.shift("i32x4.shr_u", this, n));

	public inline function eq(b:U32x4):I32x4
		return cast Ops.op2("i32x4.eq", this, b);

	public inline function ne(b:U32x4):I32x4
		return cast Ops.op2("i32x4.ne", this, b);

	// a's lanes where mask's bits are set, else b's (bitwise)
	public static inline function select(mask:I32x4, a:U32x4, b:U32x4):U32x4
		return new U32x4(Ops.op3("v128.bitselect", a, b, mask));

	// whether any bit is set
	public inline function any():Bool
		return Ops.test("v128.any_true", this) != 0;

	// whether no lane is zero
	public inline function all():Bool
		return Ops.test("i32x4.all_true", this) != 0;

	// the lanes' top bits, lane 0 lowest
	public inline function bitmask():Int
		return Ops.test("i32x4.bitmask", this);

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

	public static inline function load(b:haxe.io.Bytes, pos:Int):U32x4
		return new U32x4(Mem128.loadBytes(b, pos));

	public inline function store(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes(b, pos, this);

	public static inline function loadSpan(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U32x4
		return new U32x4(Mem128.loadSpan(s, pos));

	public inline function storeSpan(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan(s, pos, this);

	// the low 8 (4) bytes: loaded, the rest zero; stored, the rest left
	public static inline function load64(b:haxe.io.Bytes, pos:Int):U32x4
		return new U32x4(Mem128.loadBytes64(b, pos));

	public static inline function load32(b:haxe.io.Bytes, pos:Int):U32x4
		return new U32x4(Mem128.loadBytes32(b, pos));

	public inline function store64(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes64(b, pos, this);

	public inline function store32(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes32(b, pos, this);

	public static inline function loadSpan64(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U32x4
		return new U32x4(Mem128.loadSpan64(s, pos));

	public static inline function loadSpan32(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):U32x4
		return new U32x4(Mem128.loadSpan32(s, pos));

	public inline function storeSpan64(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan64(s, pos, this);

	public inline function storeSpan32(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan32(s, pos, this);

	#if (target.name == "hxmc")
	@:hxmc.unsafe(gc) public static inline function loadPtr(p:hxmc.unsafe.Ptr, off:Int):U32x4
		return new U32x4(Ops.load("v128.load", p, off));

	@:hxmc.unsafe(gc) public inline function storePtr(p:hxmc.unsafe.Ptr, off:Int):Void
		Ops.store("v128.store", p, off, this);
	#end

	public inline function min(b:U32x4):U32x4
		return new U32x4(Ops.op2("i32x4.min_u", this, b));

	public inline function max(b:U32x4):U32x4
		return new U32x4(Ops.op2("i32x4.max_u", this, b));

	public inline function lt(b:U32x4):I32x4
		return cast Ops.op2("i32x4.lt_u", this, b);

	public inline function le(b:U32x4):I32x4
		return cast Ops.op2("i32x4.le_u", this, b);

	public inline function gt(b:U32x4):I32x4
		return cast Ops.op2("i32x4.gt_u", this, b);

	public inline function ge(b:U32x4):I32x4
		return cast Ops.op2("i32x4.ge_u", this, b);

	// this clamped to [lo, hi]
	public inline function clamp(lo:U32x4, hi:U32x4):U32x4
		return max(lo).min(hi);

	// lanes of this (0-3) and b (4-7), constants
	public inline function shuffle(b:U32x4, i0:Int, i1:Int, i2:Int, i3:Int):U32x4
		return new U32x4(Ops.shuffle(this, b, i0 * 4, i0 * 4 + 1, i0 * 4 + 2, i0 * 4 + 3, i1 * 4, i1 * 4 + 1, i1 * 4 + 2, i1 * 4 + 3, i2 * 4, i2 * 4 + 1,
			i2 * 4 + 2, i2 * 4 + 3, i3 * 4, i3 * 4 + 1, i3 * 4 + 2, i3 * 4 + 3));

	public inline function swizzle(i0:Int, i1:Int, i2:Int, i3:Int):U32x4
		return shuffle(new U32x4(this), i0, i1, i2, i3);

	public static inline function make(a:Int, b:Int, c:Int, d:Int):U32x4
		return splat(a).with(1, b).with(2, c).with(3, d);

	@:op(A * B) inline function mul(b:U32x4):U32x4
		return new U32x4(Ops.op2("i32x4.mul", this, b));

	// (lane 0 + lane 1) + (lane 2 + lane 3), wrapping
	public inline function sum():Int {
		var t = add(swizzle(1, 0, 3, 2));
		return t.add(t.swizzle(2, 3, 0, 1)).get(0);
	}

	public inline function toString():String
		return '(${get(0)}, ${get(1)}, ${get(2)}, ${get(3)})';

	// lanes 0-3 (4-7) of v, zero-extended
	public static inline function extendLow(v:U16x8):U32x4
		return new U32x4(Ops.op1("i32x4.extend_low_i16x8_u", v));

	public static inline function extendHigh(v:U16x8):U32x4
		return new U32x4(Ops.op1("i32x4.extend_high_i16x8_u", v));

	public inline function toF32x4():F32x4
		return F32x4.fromU32x4(new U32x4(this));
}
