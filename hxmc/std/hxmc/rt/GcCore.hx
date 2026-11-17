package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.*;

// The object model both collectors share (the native Gc.hx and wasm/Gc.hx):
// what a heap object's header says (its type, its size, how it is scanned)
// and how a copied object is forwarded. All of it inline, so each
// collector's loops compile to what they did with their own copies.
// The header's layout is Types'; what each collector does with an object
// (its spaces, copies, remembered sets, roots) stays in its own Gc.
extern class GcCore {
	// the header's first word: the type index, then a record's slots or an array's words
	@:hxmc.unsafe(gc) public static inline function hdrW0(p:Ptr):Int
		return Mem.getI32(p, -8);

	@:hxmc.unsafe(gc) public static inline function tindexOf(p:Ptr):Int
		return Mem.getU16(p, -8);

	// forwarded (the header's first word w0): the type index is T_FWD, the
	// copy's address in slot 0, or compressed in the header's upper half
	// where the heap is below 32 GB (fwdLow; the copy has the identity hash)
	public static inline function isFwd(w0:Int):Bool
		return w0 & 0xFFFF == Types.T_FWD;

	// (p forwarded, read from its type index alone)
	@:hxmc.unsafe(gc) public static inline function isFwdAt(p:Ptr):Bool
		return tindexOf(p) == Types.T_FWD;

	// a forwarded object's copy
	@:hxmc.unsafe(gc) public static inline function fwdAddr(p:Ptr):Ptr
		return fwdLow() ? getC(p, -1) : Mem.getPtr(p, 0);

	@:hxmc.unsafe(gc) public static inline function setFwd(p:Ptr, n:Ptr) {
		Mem.setI16(p, -8, Types.T_FWD);
		setFwdAddr(p, n);
	}

	// the copy's address alone (the type index set after it: the parallel
	// collections' release store)
	@:hxmc.unsafe(gc) public static inline function setFwdAddr(p:Ptr, n:Ptr)
		if (fwdLow()) setC(p, -1, n) else Mem.setPtr(p, 0, n);

	// whether forwarding keeps the copy's address compressed in the header's
	// upper half (a constant): the program may have compressed references
	// (Mem.compact), its heap is then below 32 GB (Gc.init), and its objects
	// may have no slot (a header constructor, hxmc.ir.Facts: an enum value of
	// one 4-byte argument, in that half).
	public static inline function fwdLow():Bool
		return Mem.compact() == 1;

	// p's payload words, the header's first word w0 (Types.wordsAt: the
	// length read only for a large array)
	public static inline function wordsOf(p:Ptr, w0:Int):Int
		return Types.wordsAt(p, w0);

	@:hxmc.unsafe(gc) public static inline function nslotsOf(p:Ptr):Int
		return wordsOf(p, hdrW0(p));

	// how p is scanned: K_OBJ by its pointer map, K_PARR every slot, K_RAW not at all
	@:hxmc.unsafe(gc) public static inline function kindOf(p:Ptr):Int
		return Types.kindOfWord(hdrW0(p));

	// p with its header
	@:hxmc.unsafe(gc) public static inline function objBytes(p:Ptr):Int
		return 8 * (nslotsOf(p) + 1);

	// the pointer map (a bit per slot) of type t, or null
	public static inline function ptrmapOfType(t:Int):Ptr
		return Types.ptrmap(Types.ty(t));

	// p's type's
	@:hxmc.unsafe(gc) public static inline function ptrmapOf(p:Ptr):Ptr
		return ptrmapOfType(tindexOf(p));

	// ptrmapOfType with the type record's offset (Types.ty, Types.ptrmap)
	// folded into the load's: one wasm32 load with a constant offset
	@:hxmc.unsafe(gc) public static inline function ptrmapAt(t:Int):Ptr
		return Mem.getPtr(Mem.sym("rt_types"), 112 * t + 24);

	@:hxmc.unsafe(gc) public static inline function isPtrSlot(pm:Ptr, i:Int):Bool
		return ((Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1) != 0;

	// ---- compressed references (@:hxmc.compact): 4-byte fields holding a
	// reference's address shifted right by 3 (the heap and the image are
	// below 32 GB natively: Gc.init); null is 0. A type with them
	// (Types.hasCompact) has at most 32 slots, its compact map (a bit per
	// 4-byte half, 64) the word after its pointer map's.

	// whether the program may have types with compressed references: a
	// constant (Mem.compact: false without a @:hxmc.compact class, or where
	// the target's fields stay 8 bytes, hxmc.Main.compactRefs), so that
	// every test of them below, and the code they guard, folds away in the
	// programs without.
	public static inline function compactTypes():Bool
		return Mem.compact() == 1;

	// whether type t's objects have compressed references (word 20's bit 0,
	// Types.hasCompact)
	@:hxmc.unsafe(gc) public static inline function compactAt(t:Int):Bool
		return compactTypes() && Mem.getI32(Mem.sym("rt_types"), 112 * t + 20) & 1 != 0;

	// the compact map's entries of an object of n slots: a bit per half; an
	// object of no slots (a header constructor's value, Types.headerArg) has
	// one, its header's upper half (half -1: cmapHalf)
	public static inline function cmapHalves(n:Int):Int
		return n == 0 ? 1 : 2 * n;

	// the half of entry j of the compact map of an object of n slots
	public static inline function cmapHalf(n:Int, j:Int):Int
		return n == 0 ? -1 : j;

	// half h of the compact map pm (a type's pointer map) is a compressed reference
	@:hxmc.unsafe(gc) public static inline function isCompactHalf(pm:Ptr, h:Int):Bool
		return ((Mem.getI32At(pm, 8, h >> 5) >>> (h & 31)) & 1) != 0;

	// the compact map's halves 0 to 31 and 32 to 63
	@:hxmc.unsafe(gc) public static inline function cmapLo(pm:Ptr):Int
		return Mem.getI32(pm, 8);

	@:hxmc.unsafe(gc) public static inline function cmapHi(pm:Ptr):Int
		return Mem.getI32(pm, 12);

	// the reference in 4-byte half h of p
	@:hxmc.unsafe(gc) public static inline function getC(p:Ptr, h:Int):Ptr
		return Ptr.ofI64(((Mem.getI32At(p, 0, h) : I64) << 32) >>> 29);

	@:hxmc.unsafe(gc) public static inline function setC(p:Ptr, h:Int, v:Ptr)
		Mem.setI32At(p, 0, h, (v.toI64() >>> 3).toInt());

	// a reference field of p: 8-byte slot i, or compressed (c) 4-byte half i
	@:hxmc.unsafe(gc) public static inline function getRefAt(p:Ptr, i:Int, c:Bool):Ptr
		return c ? getC(p, i) : Ptr.ofI64(Mem.getI64At(p, 0, i));

	@:hxmc.unsafe(gc) public static inline function setRefAt(p:Ptr, i:Int, c:Bool, v:Ptr)
		if (c) setC(p, i, v) else Mem.setI64At(p, 0, i, v.toI64());
}
