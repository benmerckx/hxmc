package hxmc.rt;

import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The object header and the runtime type information (rt.h) as the
// runtime's Haxe code reads them: rt_types (written by DataGen, laid out as
// rt.h's rt_type: the same on every 64-bit target), the field, method and
// static tables, the type objects. All inline: the accessors are loads.
class Types {
	// runtime type indices (rt.h); generated types start at T_FIRST
	public static inline var T_NONE = 0;
	public static inline var T_STRING = 1;
	public static inline var T_BOXINT = 2;
	public static inline var T_BOXFLOAT = 3;
	public static inline var T_BOXBOOL = 4;
	public static inline var T_ARRAY = 5;
	public static inline var T_ADATA_P = 6;
	public static inline var T_ADATA_RAW = 7;
	public static inline var T_BYTES = 8;
	public static inline var T_TYPEOBJ = 14;
	public static inline var T_OVERFLOW = 15;
	public static inline var T_ARRAYITER = 17;
	public static inline var T_BOXI64 = 18;
	public static inline var T_NATIVE_ARRAY = 19;
	// a Date: K_RAW, the milliseconds since the epoch (a double: MemRepr.dateOf)
	public static inline var T_DATE = 20;
	// Math's class value: an extern class the runtime implements, named (Type.getClassName, resolveClass)
	public static inline var T_MATH = 21;
	public static inline var T_FIRST = 32;
	// a closure type's tag: a Dynamic converted to a function type (hxmc.ir.Facts, Dyn.unadapt)
	public static inline var TAG_DYN_ADAPTER = 1;
	// and a closure converted to another function type (Lower.adapter)
	public static inline var TAG_ADAPTER = 2;
	// object kinds
	public static inline var K_OBJ = 0;
	public static inline var K_PARR = 1;
	public static inline var K_RAW = 2;
	// rt_type.tk
	public static inline var TK_RUNTIME = 0;
	public static inline var TK_CLASS = 1;
	public static inline var TK_INTERFACE = 2;
	public static inline var TK_ENUM = 3;
	public static inline var TK_CTOR = 4;
	public static inline var TK_ANON = 5;
	public static inline var TK_CLOSURE = 6;
	public static inline var TK_BOUND = 7;
	// array element kinds
	public static inline var AK_PTR = 0;
	public static inline var AK_I32 = 1;
	public static inline var AK_F64 = 2;
	public static inline var AK_I64 = 3;
	// Bool: stored as AK_I32 is (4 bytes, 0 or 1), but read as Bool where the
	// element is boxed (Std.string, Dynamic, reflection); a NativeArray stores
	// one byte per Bool
	public static inline var AK_BOOL = 4;
	// a NativeArray made for an erased type parameter: a wrapper of its
	// storage, open until a typed view takes it, then fixed (NArray)
	public static inline var AK_OPEN = 5;
	public static inline var AK_WRAP = 6;

	// the elements of these kinds take 4 bytes
	public static inline function ak4(k:Int):Bool
		return k == AK_I32 || k == AK_BOOL;

	// ---- headers: slot count bits 0..27, kind 28..31, type index 32..47,
	// identity hash 48..63

	public static inline function tindex(o:Dynamic):Int
		return Mem.getU16(Mem.addr(o), -4);

	public static inline function nslots(o:Dynamic):Int
		return Mem.getI32(Mem.addr(o), -8) & 0x0FFFFFFF;

	public static inline function kind(o:Dynamic):Int
		return (Mem.getI32(Mem.addr(o), -8) >>> 28) & 15;

	// ---- rt_type (112 bytes)

	public static inline function ty(t:Int):Ptr
		return Mem.sym("rt_types").add(t * 112);

	public static inline function name(ty:Ptr):Ptr
		return Mem.getPtr(ty, 0);

	public static inline function tk(ty:Ptr):Int
		return Mem.getU8(ty, 8);

	public static inline function sup(ty:Ptr):Int
		return Mem.getI32(ty, 12);

	public static inline function slotCount(ty:Ptr):Int
		return Mem.getI32(ty, 16);

	public static inline function ptrmap(ty:Ptr):Ptr
		return Mem.getPtr(ty, 24);

	public static inline function nfields(ty:Ptr):Int
		return Mem.getI32(ty, 32);

	// rt_field (12 bytes): int32 fid, int32 slot, char kind
	public static inline function field(ty:Ptr, i:Int):Ptr
		return Mem.getPtr(ty, 40).add(12 * i);

	public static inline function nmethods(ty:Ptr):Int
		return Mem.getI32(ty, 48);

	// rt_method (24 bytes): int32 fid, void *fn, int32 sig
	public static inline function method(ty:Ptr, i:Int):Ptr
		return Mem.getPtr(ty, 56).add(24 * i);

	public static inline function nifaces(ty:Ptr):Int
		return Mem.getI32(ty, 64);

	public static inline function iface(ty:Ptr, i:Int):Int
		return Mem.getI32At(Mem.getPtr(ty, 72), 0, i);

	public static inline function tag(ty:Ptr):Int
		return Mem.getI32(ty, 80);

	// a constructor without arguments: the rt_globals index of its value, else -1
	public static inline function single(ty:Ptr):Int
		return Mem.getI32(ty, 84) - 1;

	public static inline function ctor(ty:Ptr, i:Int):Int
		return Mem.getI32At(Mem.getPtr(ty, 88), 0, i);

	// a class's entry for Type.createInstance (hxmc.ir.ClassInfo.maker, where
	// a constructor's singleton is): 0 none (no live code can have the class
	// value), 1 no constructor (the call fails), 2 + s: makerFn, called as a
	// bound method of signature s on the new instance
	public static inline function maker(ty:Ptr):Int
		return Mem.getI32(ty, 84);

	public static inline function makerFn(ty:Ptr):Ptr
		return Mem.getPtr(ty, 88);

	public static inline function nstatics(ty:Ptr):Int
		return Mem.getI32(ty, 96);

	// rt_static (24 bytes): int32 fid, char kind, int32 idx, int32 rank (its
	// place in Type.getClassFields), void *ptr; sorted by fid
	public static inline function stat(ty:Ptr, i:Int):Ptr
		return Mem.getPtr(ty, 104).add(24 * i);

	public static inline function fFid(f:Ptr):Int
		return Mem.getI32(f, 0);

	public static inline function fSlot(f:Ptr):Int
		return Mem.getI32(f, 4);

	public static inline function fKind(f:Ptr):Int
		return Mem.getU8(f, 8);

	public static inline function mFid(m:Ptr):Int
		return Mem.getI32(m, 0);

	public static inline function mFn(m:Ptr):Ptr
		return Mem.getPtr(m, 8);

	public static inline function mSig(m:Ptr):Int
		return Mem.getI32(m, 16);

	// the type object (a Class<T>/Enum<T> value) of type index t
	public static inline function typeObj(t:Int):Dynamic
		return Mem.obj(Mem.sym("rt_type_objs").add(16 * t + 8));

	// the type index a type object describes
	public static inline function described(c:Dynamic):Int
		return Mem.getI32(Mem.addr(c), 0);

	// rt_globals[i] (the reference globals: roots, no barrier)
	public static inline function globalSlot(i:Int):Ptr
		return Mem.getPtr(Mem.sym("rt_globals"), 0).add(8 * i);
}
