package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The object header and the runtime type information (rt.h) as the
// runtime's Haxe code reads them: rt_types (written by DataGen, laid out as
// rt.h's rt_type: the same on every 64-bit target), the field, method and
// static tables, the type objects. All inline: the accessors are loads.
class Types {
	// runtime type indices; generated types start at T_FIRST. 16 to 31 are
	// arrays (isArray): 16 to 23 of bytes (isRawArray), 24 to 31 of
	// references; the others records (the headers, below)
	public static inline var T_NONE = 0;
	public static inline var T_ARRAYITER = 1;
	public static inline var T_BOXINT = 2;
	public static inline var T_BOXFLOAT = 3;
	public static inline var T_BOXBOOL = 4;
	public static inline var T_ARRAY = 5;
	public static inline var T_BOXI64 = 6;
	// the NativeArray made for an erased type parameter (NArray): open, fixed
	public static inline var T_NATIVE_OPEN = 7;
	public static inline var T_NATIVE_WRAP = 8;
	public static inline var T_TYPEOBJ = 14;
	public static inline var T_STRING = 16;
	public static inline var T_ADATA_RAW = 17; // slots
	public static inline var T_NATIVE = 18; // slots: a C resource, an AtomicInt cell
	// NativeArray storage, by element kind: T_NATIVE_ARRAY - AK_* (naType:
	// AK_BYTE's 19 to AK_PTR's 24, references). T_BYTES: the storage of bytes
	// (haxe.io.BytesData: NativeArray<hxmc.Byte>), which a haxe.io.Bytes holds
	public static inline var T_BYTES = 19;
	public static inline var T_NATIVE_ARRAY = 24;
	public static inline var T_ADATA_P = 25; // slots of references
	public static inline var T_OVERFLOW = 26;
	public static inline var T_NATIVE_REFS = 27; // a C resource (slot 0) and references
	// a Date: a record of one slot, the milliseconds since the epoch (a double: MemRepr.dateOf)
	public static inline var T_DATE = 15;
	// Math's class value: an extern class the runtime implements, named
	// (Type.getClassName, resolveClass); no instance has it (one of the free
	// indices, 28 to 31)
	public static inline var T_MATH = 28;
	public static inline var T_FIRST = 32;
	// (the header of an object the collector copied)
	public static inline var T_FWD = 0xFFFF;
	// a closure type's tag: a Dynamic converted to a function type (hxmc.ir.Facts, Dyn.unadapt)
	public static inline var TAG_DYN_ADAPTER = 1;
	// and a closure converted to another function type (Lower.adapter)
	public static inline var TAG_ADAPTER = 2;
	// object kinds: what Mem.alloc makes (K_OBJ a record, else an array of
	// 8-byte slots), and how the collector scans (kind)
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
	// Bool: one byte (0 or 1), read as Bool where the element is boxed
	// (Std.string, Dynamic, reflection)
	public static inline var AK_BOOL = 4;
	// hxmc.Byte: one byte, read as an Int from 0 to 255 (a NativeArray's
	// only, haxe.io.BytesData: no Array is of this kind)
	public static inline var AK_BYTE = 5;
	// the kinds of NativeArray storage: AK_PTR to AK_BYTE
	public static inline var AK_COUNT = 6;
	// a NativeArray made for an erased type parameter: a wrapper of its
	// storage, open until a typed view takes it, then fixed (NArray)
	public static inline var AK_OPEN = 6;
	public static inline var AK_WRAP = 7;

	// the bytes of an element of kind k (a NativeArray's, so an Array's)
	public static inline function akSize(k:Int):Int
		return k >= AK_BOOL ? 1 : k == AK_I32 ? 4 : 8;

	// ---- headers (docs/plans/heap-layout.md): the 8 bytes before an
	// object, its type index first (a u16 at -8), which decides the rest:
	//   record (a size its type fixes): its slots (a u16 at -6; 65534 at
	//     most), its identity hash (a u32 at -4; the NativeArray wrapper: its
	//     length there);
	//   array (isArray): its payload's 8-byte words (a u16 at -6; 0xFFFF:
	//     that many or more: lenWords), its length in elements (a u32 at -4);
	//     whether the elements are references, and their size, its type says;
	//   string: its words as an array's, its content hash (a u32 at -4, 0
	//     until computed); its length (a u32 at 0), then its UTF-16 units;
	//   forwarded (by the collector): T_FWD, the copy's address in slot 0
	// (every object on the heap has a slot: an empty array or string is static).

	public static inline function isArray(t:Int):Bool
		return t & 0xFFF0 == 16;

	public static inline function isRecord(t:Int):Bool
		return !isArray(t);

	// an array without references (a string too), by its type or its
	// header's first word
	public static inline function isRawArray(t:Int):Bool
		return t & 0xFFF8 == 16;

	// the type of NativeArray storage of element kind k, and the kind of type t
	public static inline function naType(k:Int):Int
		return T_NATIVE_ARRAY - k;

	public static inline function naKind(t:Int):Int
		return T_NATIVE_ARRAY - t;

	// an array's first header word: its type t, its payload's words (0xFFFF
	// from that many on: the sign of 0xFFFE - words, without a branch)
	public static inline function arrWord(t:Int, words:Int):Int
		return t | ((words | ((0xFFFE - words) >> 31)) << 16);

	// the header of a record of type t (its hash 0)
	public static inline function recordHdr(t:Int, slots:Int):I64
		return ((t | (slots << 16) : I64) << 32) >>> 32;

	// the header of an array whose first word is w0
	public static inline function arrayHdr(w0:Int, len:Int):I64
		return (((w0 : I64) << 32) >>> 32) | ((len : I64) << 32);

	// the payload's 8-byte words of the object at p whose header's first
	// word is w0 (not forwarded): the header's, but an array's of 0xFFFF
	// words or more (lenWords: its length, a string's at p, the others' at p - 4)
	public static inline function wordsAt(p:Ptr, w0:Int):Int {
		var n = w0 >>> 16;
		return n == 0xFFFF ? lenWords(w0 & 0xFFFF, Mem.getI32(p, w0 & 0xFFFF == T_STRING ? 0 : -4)) : n;
	}

	// the words of an array of type t and length len, by its elements' size:
	// a string's units after its length, NativeArray storage's by its kind,
	// else 8-byte slots (inline: the collector's loops make no call)
	public static inline function lenWords(t:Int, len:Int):Int {
		var k = naKind(t);
		var size = t == T_STRING ? 2 : Mem.ult(k, AK_COUNT) ? akSize(k) : 8;
		return ((((len : I64) * size) + (t == T_STRING ? 11 : 7)) >>> 3).toInt();
	}

	// how an object whose first header word is w0 is scanned: K_OBJ (a
	// record, by its type's pointer map), K_PARR (every slot), K_RAW (none)
	public static inline function kindOfWord(w0:Int):Int {
		var t = w0 & 0xFFFF;
		return isArray(t) ? K_RAW - ((t >>> 3) & 1) : K_OBJ;
	}

	public static inline function isNativeArray(t:Int):Bool
		return Mem.ult(naKind(t), AK_COUNT) || t == T_NATIVE_OPEN || t == T_NATIVE_WRAP;

	public static inline function tindex(o:Dynamic):Int
		return Mem.getU16(Mem.addr(o), -8);

	// the payload's 8-byte words
	public static inline function nslots(o:Dynamic):Int
		return wordsAt(Mem.addr(o), Mem.getI32(Mem.addr(o), -8));

	// an array's length (in elements)
	public static inline function arrLength(o:Dynamic):Int
		return Mem.getI32(Mem.addr(o), -4);

	// how the collector scans o: by its pointer map (a record), every slot
	// (references) or not at all
	public static inline function kind(o:Dynamic):Int
		return kindOfWord(Mem.getI32(Mem.addr(o), -8));

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
