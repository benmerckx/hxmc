package hxmc.rt;

import hxmc.unsafe.*;

// The object model both collectors share (the native Gc.hx and wasm/Gc.hx):
// what a heap object's header says (its type, its size, how it is scanned)
// and how a copied object is forwarded. All of it inline, so each
// collector's loops compile to what they did with their own copies.
// The header's layout is Types'; what each collector does with an object
// (its spaces, copies, remembered sets, roots) stays in its own Gc.
extern class GcCore {
	// the header's first word: the type index, then a record's slots or an array's words
	public static inline function hdrW0(p:Ptr):Int
		return Mem.getI32(p, -8);

	public static inline function tindexOf(p:Ptr):Int
		return Mem.getU16(p, -8);

	// forwarded (the header's first word w0): the type index is T_FWD, the
	// copy's address is in slot 0
	public static inline function isFwd(w0:Int):Bool
		return w0 & 0xFFFF == Types.T_FWD;

	// (p forwarded, read from its type index alone)
	public static inline function isFwdAt(p:Ptr):Bool
		return tindexOf(p) == Types.T_FWD;

	// a forwarded object's copy
	public static inline function fwdAddr(p:Ptr):Ptr
		return Mem.getPtr(p, 0);

	public static inline function setFwd(p:Ptr, n:Ptr) {
		Mem.setI16(p, -8, Types.T_FWD);
		Mem.setPtr(p, 0, n);
	}

	// p's payload words, the header's first word w0 (Types.wordsAt: the
	// length read only for a large array)
	public static inline function wordsOf(p:Ptr, w0:Int):Int
		return Types.wordsAt(p, w0);

	public static inline function nslotsOf(p:Ptr):Int
		return wordsOf(p, hdrW0(p));

	// how p is scanned: K_OBJ by its pointer map, K_PARR every slot, K_RAW not at all
	public static inline function kindOf(p:Ptr):Int
		return Types.kindOfWord(hdrW0(p));

	// p with its header
	public static inline function objBytes(p:Ptr):Int
		return 8 * (nslotsOf(p) + 1);

	// the pointer map (a bit per slot) of type t, or null
	public static inline function ptrmapOfType(t:Int):Ptr
		return Types.ptrmap(Types.ty(t));

	// p's type's
	public static inline function ptrmapOf(p:Ptr):Ptr
		return ptrmapOfType(tindexOf(p));

	// ptrmapOfType with the type record's offset (Types.ty, Types.ptrmap)
	// folded into the load's: one wasm32 load with a constant offset
	public static inline function ptrmapAt(t:Int):Ptr
		return Mem.getPtr(Mem.sym("rt_types"), 112 * t + 24);

	public static inline function isPtrSlot(pm:Ptr, i:Int):Bool
		return ((Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1) != 0;
}
