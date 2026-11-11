package hxmc.rt;

import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.rt.Repr;
import hxmc.rt.Types.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

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

	// a Float box's number, else 0
	public static function float(v:Dynamic):Float
		return index(v) == T_BOXFLOAT ? Mem.getF64(Mem.addr(v), 0) : 0;

	// an Int64 box's number, else 0
	public static function i64(v:Dynamic):I64
		return index(v) == T_BOXI64 ? Mem.getI64(Mem.addr(v), 0) : 0;

	// a Date's milliseconds, else 0
	public static function date(v:Dynamic):Float
		return index(v) == T_DATE ? Repr.dateMs(v) : 0;

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

	// the type indices of the interfaces a class implements
	public static function ifaces(t:TypeIndex):ReadOnlySpan<Int>
		return ReadOnlySpan.unsafeOf((cast Mem.getPtr(ty(t), 72) : Ptr<Int>), nifaces(ty(t)));
}
