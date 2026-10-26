package hxmc.unsafe;

import hxmc.I64;

// A raw machine address (docs/plans/lowlevel.md, "C interop"): an int64_t the
// collector neither traces nor moves. `Ptr` alone (Ptr<Void>) is C's
// `void *`; `Ptr<T>` points at a T: a scalar (Int8 .. UInt64, Int, Float,
// Float32, Bool: C's bool, one byte), another Ptr, or a @:hxmc.struct class
// (whose fields are reached through the pointer: `p.value.x`, `p[i].x`).
// Like C's `void *`, Ptr<Void> converts to and from every Ptr<T>.
//
// The address of a heap object (Mem.addr) is valid only until the next GC
// point: the compiler rejects one that is live across a GC point outside a
// @:hxmc.unsafe function (Facts' raw-address check).
abstract Ptr<T = Void>(I64) {
	public static inline function nil<T>():Ptr<T>
		return new Ptr(0);

	public inline function new(v:I64)
		this = v;

	public static inline function ofI64<T>(v:I64):Ptr<T>
		return new Ptr(v);

	public inline function toI64():I64
		return this;

	public inline function isNull():Bool
		return this == 0;

	// the address `bytes` further (a signed 32-bit offset)
	public inline function add(bytes:Int):Ptr<T>
		return new Ptr(this + (bytes : I64));

	public inline function addL(bytes:I64):Ptr<T>
		return new Ptr(this + bytes);

	// the byte distance from `p` to this address
	public inline function diff(p:Ptr<T>):I64
		return this - p.toI64();

	@:op(a == b) static inline function eq<T>(a:Ptr<T>, b:Ptr<T>):Bool
		return a.toI64() == b.toI64();

	@:op(a != b) static inline function ne<T>(a:Ptr<T>, b:Ptr<T>):Bool
		return !(a.toI64() == b.toI64());

	// unsigned comparisons (addresses)
	public inline function ult(p:Ptr<T>):Bool
		return Mem.ult(this, p.toI64());

	public inline function uge(p:Ptr<T>):Bool
		return !Mem.ult(this, p.toI64());

	// C's void * conversions
	@:to inline function toVoid():Ptr<Void>
		return new Ptr(this);

	@:from static inline function ofVoid<T>(p:Ptr<Void>):Ptr<T>
		return new Ptr(p.toI64());

	// the address as a Ptr<Void>, which converts to any Ptr<U>:
	// `var q:Ptr<Int8> = p.raw();`
	public inline function raw():Ptr<Void>
		return new Ptr(this);

	// ---- typed access (expanded by the compiler, FnLower.ptrAccess: the
	// element type T decides the load or store; a struct's field access through
	// `value` or `[i]` is the field's load or store, without a copy)

	// *p
	public var value(get, set):T;

	extern function get_value():T;

	extern function set_value(v:T):T;

	// p[i]: the i-th T from p
	@:arrayAccess extern function get(i:Int):T;

	@:arrayAccess extern function set(i:Int, v:T):T;

	// p + i (in elements of T)
	extern public function offset(i:Int):Ptr<T>;
}
