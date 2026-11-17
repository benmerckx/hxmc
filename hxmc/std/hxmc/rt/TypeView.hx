package hxmc.rt;

import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.rt.Repr;
import hxmc.rt.Types.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// An index of a row of the type table (rt_types: DataGen writes a row for
// every index below rt_ntypes, the runtime's 0 to T_FIRST - 1 included), so
// TypeView reads the row without a bound check. A proof (@:hxmc.proof): only
// TypeView makes one; a safe kernel holds, passes, compares and returns it.
@:hxmc.proof abstract TypeIndex(Int) to Int {
	@:op(A < B) static function lt(a:TypeIndex, b:Int):Bool;

	@:op(A >= B) static function ge(a:TypeIndex, b:Int):Bool;
}

// A word of the tagged encoding (hxmc.rt.Tagged) whose reference, if it is
// one, is a live object or null: a type parameter's word as the generated
// code passes it (MemLower's slow paths). A proof: TypeView.ref reads it.
@:hxmc.proof abstract Word(I64) to I64 {}

// A value's header and the type table (hxmc.rt.Types) read for kernels, as
// StrView reads a string's layout: a value's type index (T_NONE of null:
// row 0, which no value has), a box's number, a type object's type, and of
// a type index its kind, super type, tag and interfaces.
//
// Not every object has a slot (a header constructor's value has none:
// MirBuild's ENewEnum, GcCore.cmapHalves), so a payload is read only after
// its type is tested here, as the caller has already tested it (Opt drops
// the repeated test). (No function calls another: each is inlined in one
// round, Driver.)
@:keep @:hxmc.kernel @:hxmc.unsafe
class TypeView {
	public static function of(v:Dynamic):TypeIndex
		return cast index(v);

	static inline function index(v:Dynamic):Int
		return Repr.isNull(v) ? T_NONE : tindex(v);

	// a word's reference (null of a scalar's word)
	public static function ref(w:Word):Dynamic
		return Tagged.isScalar(w) ? null : Mem.obj(new Ptr(w));

	// the same object (or both null)
	public static function same(a:Dynamic, b:Dynamic):Bool
		return Repr.same(a, b);

	// an Int or Bool box's 32 bits, else 0
	public static function int(v:Dynamic):Int {
		var t = index(v);
		return t == T_BOXINT || t == T_BOXBOOL ? Mem.getI32(Mem.addr(v), 0) : 0;
	}

	// a string as a String (a view reads it as one), else "": the caller has
	// tested it (Opt drops the repeated test)
	public static function string(v:Dynamic):String
		return isString(index(v)) ? v : "";

	// a Float box's number, else 0
	public static function float(v:Dynamic):Float
		return index(v) == T_BOXFLOAT ? Mem.getF64(Mem.addr(v), 0) : 0;

	// an Int64 box's number, else 0
	public static function i64(v:Dynamic):I64
		return index(v) == T_BOXI64 ? Mem.getI64(Mem.addr(v), 0) : 0;

	// a Date's milliseconds, else 0
	public static function date(v:Dynamic):Float
		return index(v) == T_DATE ? Repr.dateMs(v) : 0;

	// a Date's time as a typed read of it has it: null faults (Null Access:
	// Faults; WebAssembly reads 0 there), another value's is 0
	public static function time(v:Dynamic):Float
		return tindex(v) == T_DATE ? Repr.dateMs(v) : 0;

	// the type a type object stands for, else T_NONE
	public static function described(v:Dynamic):TypeIndex
		return cast(index(v) == T_TYPEOBJ ? Types.described(v) : T_NONE);

	// (TK_*)
	public static function kind(t:TypeIndex):Int
		return tk(ty(t));

	// the super type (a constructor's: its enum), T_NONE of none
	public static function sup(t:TypeIndex):TypeIndex {
		var s = Types.sup(ty(t));
		return cast(s < 0 ? T_NONE : s);
	}

	public static function tag(t:TypeIndex):Int
		return Types.tag(ty(t));

	// an enum value's constructor (its type's tag); of null the header's
	// read faults: Null Access, as a typed access of null (Faults; Type.enumIndex
	// tests on WebAssembly)
	public static function enumIndex(v:Dynamic):Int
		return Types.tag(ty(tindex(v)));

	// what an adapter adapts (a closure of tag TAG_ADAPTER or TAG_DYN_ADAPTER,
	// Lower.adapter, dynAdapter: its capture), else null
	public static function adaptee(f:Dynamic):Dynamic {
		var t = index(f);
		if (t < T_FIRST || tk(ty(t)) != TK_CLOSURE) return null;
		var g = Types.tag(ty(t));
		return g == TAG_ADAPTER || g == TAG_DYN_ADAPTER ? Mem.getRef(Mem.addr(f), 8) : null;
	}

	// one of the runtime's types (below T_FIRST: its row always there), else T_NONE
	public static function runtime(c:Int):TypeIndex
		return cast(c >= 0 && c < T_FIRST ? c : T_NONE);

	// the type object of a type (a static object: Class<T>, Enum<T>)
	public static function typeObj(t:TypeIndex):Dynamic
		return Types.typeObj(t);

	// an Array's element kind (AK_*), -1 of any other value; its elements of
	// one kind as a span as long as it (an Array's length is within its
	// storage), none of another kind or value; an element of references
	// (AK_PTR), null past the end
	public static function arrayKind(a:Dynamic):Int
		return Repr.isNull(a) || tindex(a) != T_ARRAY ? -1 : Repr.arrKind(a);

	static inline function arrayLength(a:Dynamic, k:Int):Int
		return Repr.isNull(a) || tindex(a) != T_ARRAY || Repr.arrKind(a) != k ? 0 : Repr.arrLen(a);

	public static function ints(a:Dynamic):ReadOnlySpan<Int> {
		var n = arrayLength(a, AK_I32);
		return ReadOnlySpan.unsafeOf((cast(n == 0 ? Ptr.nil() : Repr.arrData(a)) : Ptr<Int>), n);
	}

	public static function bools(a:Dynamic):ReadOnlySpan<UInt8> {
		var n = arrayLength(a, AK_BOOL);
		return ReadOnlySpan.unsafeOf((cast(n == 0 ? Ptr.nil() : Repr.arrData(a)) : Ptr<UInt8>), n);
	}

	public static function floats(a:Dynamic):ReadOnlySpan<Float> {
		var n = arrayLength(a, AK_F64);
		return ReadOnlySpan.unsafeOf((cast(n == 0 ? Ptr.nil() : Repr.arrData(a)) : Ptr<Float>), n);
	}

	public static function longs(a:Dynamic):ReadOnlySpan<I64> {
		var n = arrayLength(a, AK_I64);
		return ReadOnlySpan.unsafeOf((cast(n == 0 ? Ptr.nil() : Repr.arrData(a)) : Ptr<I64>), n);
	}

	public static function element(a:Dynamic, i:Int):Dynamic {
		var n = arrayLength(a, AK_PTR);
		return Mem.ult(i, n) ? Mem.getRefAt(Repr.arrData(a), 0, i) : null;
	}

	// the type indices of the interfaces a class implements
	public static function ifaces(t:TypeIndex):ReadOnlySpan<Int>
		return ReadOnlySpan.unsafeOf((cast Mem.getPtr(ty(t), 72) : Ptr<Int>), nifaces(ty(t)));
}
