package hxmc.simd;

// Two signed 64-bit lanes (docs/plans/simd.md): a value (16 bytes, in a vector register on hxmc),
// never null, copied on assignment. Lane arithmetic wraps unless named
// saturating; lane indices are constants; comparisons give masks (I64x2: all
// ones where true).
abstract I64x2(V128) {
	inline function new(v:V128)
		this = v;

	@:to inline function bits():V128
		return this;

	// x in every lane (its low bits)
	public static inline function splat(x:haxe.Int64):I64x2
		return new I64x2(Ops.splatI64("i64x2.splat", x));

	public static inline function zero():I64x2
		return new I64x2(Ops.const(0, 0, 0, 0));

	// lane i (a constant)
	public inline function get(i:Int):haxe.Int64
		return Ops.extractI64("i64x2.extract_lane", this, i);

	// this with lane i (a constant) x
	public inline function with(i:Int, x:haxe.Int64):I64x2
		return new I64x2(Ops.replaceI64("i64x2.replace_lane", this, i, x));

	@:op(A + B) inline function add(b:I64x2):I64x2
		return new I64x2(Ops.op2("i64x2.add", this, b));

	@:op(A - B) inline function sub(b:I64x2):I64x2
		return new I64x2(Ops.op2("i64x2.sub", this, b));

	@:op(A & B) inline function and(b:I64x2):I64x2
		return new I64x2(Ops.op2("v128.and", this, b));

	@:op(A | B) inline function or(b:I64x2):I64x2
		return new I64x2(Ops.op2("v128.or", this, b));

	@:op(A ^ B) inline function xor(b:I64x2):I64x2
		return new I64x2(Ops.op2("v128.xor", this, b));

	@:op(~A) inline function not():I64x2
		return new I64x2(Ops.op1("v128.not", this));

	// this & ~b
	public inline function andNot(b:I64x2):I64x2
		return new I64x2(Ops.op2("v128.andnot", this, b));

	// shifts by n modulo the lane's width
	@:op(A << B) inline function shl(n:Int):I64x2
		return new I64x2(Ops.shift("i64x2.shl", this, n));

	@:op(A >> B) inline function shr(n:Int):I64x2
		return new I64x2(Ops.shift("i64x2.shr_s", this, n));

	@:op(A >>> B) inline function ushr(n:Int):I64x2
		return new I64x2(Ops.shift("i64x2.shr_u", this, n));

	public inline function eq(b:I64x2):I64x2
		return cast Ops.op2("i64x2.eq", this, b);

	public inline function ne(b:I64x2):I64x2
		return cast Ops.op2("i64x2.ne", this, b);

	// a's lanes where mask's bits are set, else b's (bitwise)
	public static inline function select(mask:I64x2, a:I64x2, b:I64x2):I64x2
		return new I64x2(Ops.op3("v128.bitselect", a, b, mask));

	// whether any bit is set
	public inline function any():Bool
		return Ops.test("v128.any_true", this) != 0;

	// whether no lane is zero
	public inline function all():Bool
		return Ops.test("i64x2.all_true", this) != 0;

	// the lanes' top bits, lane 0 lowest
	public inline function bitmask():Int
		return Ops.test("i64x2.bitmask", this);

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

	public static inline function load(b:haxe.io.Bytes, pos:Int):I64x2
		return new I64x2(Mem128.loadBytes(b, pos));

	public inline function store(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes(b, pos, this);

	public static inline function loadSpan(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):I64x2
		return new I64x2(Mem128.loadSpan(s, pos));

	public inline function storeSpan(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan(s, pos, this);

	// the low 8 (4) bytes: loaded, the rest zero; stored, the rest left
	public static inline function load64(b:haxe.io.Bytes, pos:Int):I64x2
		return new I64x2(Mem128.loadBytes64(b, pos));

	public static inline function load32(b:haxe.io.Bytes, pos:Int):I64x2
		return new I64x2(Mem128.loadBytes32(b, pos));

	public inline function store64(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes64(b, pos, this);

	public inline function store32(b:haxe.io.Bytes, pos:Int):Void
		Mem128.storeBytes32(b, pos, this);

	public static inline function loadSpan64(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):I64x2
		return new I64x2(Mem128.loadSpan64(s, pos));

	public static inline function loadSpan32(s:hxmc.ReadOnlySpan<hxmc.unsafe.UInt8>, pos:Int):I64x2
		return new I64x2(Mem128.loadSpan32(s, pos));

	public inline function storeSpan64(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan64(s, pos, this);

	public inline function storeSpan32(s:hxmc.Span<hxmc.unsafe.UInt8>, pos:Int):Void
		Mem128.storeSpan32(s, pos, this);

	#if (target.name == "hxmc")
	public static inline function loadPtr(p:hxmc.unsafe.Ptr, off:Int):I64x2
		return new I64x2(Ops.load("v128.load", p, off));

	public inline function storePtr(p:hxmc.unsafe.Ptr, off:Int):Void
		Ops.store("v128.store", p, off, this);
	#end

	// lanes of this (0-1) and b (2-3), constants
	public inline function shuffle(b:I64x2, i0:Int, i1:Int):I64x2
		return new I64x2(Ops.shuffle(this, b, i0 * 8, i0 * 8 + 1, i0 * 8 + 2, i0 * 8 + 3, i0 * 8 + 4, i0 * 8 + 5, i0 * 8 + 6, i0 * 8 + 7, i1 * 8,
			i1 * 8 + 1, i1 * 8 + 2, i1 * 8 + 3, i1 * 8 + 4, i1 * 8 + 5, i1 * 8 + 6, i1 * 8 + 7));

	@:op(-A) inline function neg():I64x2
		return new I64x2(Ops.op1("i64x2.neg", this));

	public static inline function extendLow(v:I32x4):I64x2
		return new I64x2(Ops.op1("i64x2.extend_low_i32x4_s", v));

	public static inline function extendHigh(v:I32x4):I64x2
		return new I64x2(Ops.op1("i64x2.extend_high_i32x4_s", v));

	public static inline function extendLowU(v:U32x4):I64x2
		return new I64x2(Ops.op1("i64x2.extend_low_i32x4_u", v));

	public static inline function extendHighU(v:U32x4):I64x2
		return new I64x2(Ops.op1("i64x2.extend_high_i32x4_u", v));

	public inline function toString():String
		return '(${get(0)}, ${get(1)})';
}
