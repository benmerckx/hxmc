package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.*;

// The data stacks of scoped memory (docs/plans/lowlevel.md, "Scoped
// memory"): per thread, up to K stacks, each a reservation with a bump
// pointer, made on first use. Stack 0 is the fixed one (what does not grow:
// a Str's copy, a Grow's header); a Grow or a Pool claims one of the others
// for itself alone (a bit in the owned mask), so its elements are always on
// top and growth never moves them. A scope marks (stack 0's top and the
// owned mask, two thread-local variables read into locals of the frame:
// FnLower) where it starts and resets where it ends: stack 0's top back,
// the stacks claimed since released (their tops back to their bases: a
// stack nobody owns is always empty above its base). Natively each stack reserves RESERVE bytes of address
// space, committed as touched (Os.reserve); on wasm32 it is a region of the
// linear memory (Heap.regionZero) of RT_DATA_STACK_MB megabytes (256 unless
// set). Running past a stack's end, or more Grows at once than stacks,
// aborts with a message: scoped code cannot throw.
//
// The table (malloc'ed, per thread): per stack its top, end and base (at
// 16 + 32 * i); stack 0's top and end, and the owned mask, are thread-local
// variables of their own (a mark is two loads, no call). No GC reference
// anywhere: the collector never scans or moves any of it.
@:allow(hxmc.scoped)
class DataStacks {
	public static inline var K = 16;
	static inline var TOP = 0;
	static inline var END = 8;
	static inline var BASE = 16;
	static inline var RESERVE:Int = 1 << 30; // (natively: 8 * this, below)

	@:hxmc.threadLocal static var table:Ptr;
	// stack 0's top (null before its first allocation, and after a reset to
	// a mark taken then: its base), base and end (null until the table is
	// made), the owned mask (@:keep: the lowering reads and sets them,
	// FnLower.mark)
	@:keep @:hxmc.threadLocal static var top0:Ptr;
	@:hxmc.threadLocal static var base0:Ptr;
	@:hxmc.threadLocal static var end0:Ptr;
	@:keep @:hxmc.threadLocal static var owned:Int;

	static inline function stack(t:Ptr, i:Int):Ptr
		return t.add(16 + 32 * i);

	// the table, made on first use
	static inline function tab():Ptr {
		var t = table;
		return t.isNull() ? init() : t;
	}

	@:hxmc.unsafe static function init():Ptr {
		var bytes:I64 = 16 + 32 * K;
		var t = LibC.malloc(bytes);
		LibC.memset(t, 0, bytes);
		table = t;
		open(t, 0);
		base0 = Mem.getPtr(stack(t, 0), BASE);
		end0 = Mem.getPtr(stack(t, 0), END);
		#if (hxmc.target != "wasm32-wasi")
		Threads.dataStacksExit = Callback.addr(threadExit);
		#end
		return t;
	}

	// stack i reserved (its top at its base)
	@:hxmc.unsafe static function open(t:Ptr, i:Int) {
		var s = stack(t, i);
		#if (hxmc.target == "wasm32-wasi")
		var mb = hxmc.rt.wasm.Wasi.envInt("RT_DATA_STACK_MB", 256);
		if (mb < 1) mb = 1;
		var bytes = mb << 20;
		var p = hxmc.rt.wasm.Heap.regionZero(bytes);
		Mem.setPtr(s, END, p.add(bytes));
		#else
		var bytes:I64 = (RESERVE : I64) * 8;
		var p = Os.reserve(bytes);
		if (p.isNull()) die(Mem.cstr("hxmc: scoped memory: no address space for a data stack\n"));
		Mem.setPtr(s, END, p.addL(bytes));
		#end
		Mem.setPtr(s, BASE, p);
		Mem.setPtr(s, TOP, p);
	}

	// ---- allocation (the root checker knows these: @:hxmc.alloc, fresh memory of the scope)

	// `bytes` bytes on the fixed stack, 8-byte aligned, not zeroed
	@:hxmc.unsafe @:hxmc.alloc public static function alloc(bytes:Int):Ptr {
		var p = top0;
		if (p.isNull()) p = base0;
		var q = p.add((bytes + 7) & ~7);
		// (no table yet: end0 is null)
		if (Mem.ult(end0.toI64(), q.toI64())) return allocFirst(bytes);
		top0 = q;
		return p;
	}

	// (the table made first)
	@:hxmc.unsafe @:hxmc.alloc static function allocFirst(bytes:Int):Ptr {
		tab();
		var p = top0;
		if (p.isNull()) p = base0;
		var q = p.add((bytes + 7) & ~7);
		if (Mem.ult(end0.toI64(), q.toI64())) overflow();
		top0 = q;
		return p;
	}

	// a scope-bound object (FnLower.newBound): an object's header w0 (its
	// type index, its slots from bit 16) and its slots zeroed, on the fixed
	// stack; its address past the header, as an object's
	@:keep @:hxmc.unsafe @:hxmc.alloc public static function object(w0:Int):Ptr {
		var bytes = 8 * ((w0 >>> 16) + 1);
		var p = alloc(bytes);
		// (a few words: stores, no call)
		Mem.setI32(p, 0, w0);
		Mem.setI32(p, 4, 0);
		var i = 8;
		while (i < bytes) {
			Mem.setI64(p, i, 0);
			i += 8;
		}
		return p.add(8);
	}

	// a copy of the units of s on the fixed stack, a 0 unit after them (for
	// the system: Str.copyOf, GC code)
	@:hxmc.unsafe @:hxmc.alloc public static function copyString(s:String):Ptr {
		var n = Str.len(s);
		var p = alloc(2 * n + 2);
		LibC.memcpy(p, Str.unitsAddr(s), (2 * n : I64));
		Mem.setI16(p, 2 * n, 0);
		return p;
	}

	// a String of the n units at p (Str.toString: GC code)
	public static function stringOf(p:Ptr, n:Int):String {
		var r = Str.make(n);
		LibC.memcpy(Str.unitsAddr(r), p, (2 * n : I64));
		return r;
	}

	// a stack of its own for a Grow or a Pool: its index
	@:hxmc.unsafe @:hxmc.alloc public static function claim():Int {
		var t = tab();
		var o = owned;
		var i = 1;
		while (i < K && o & (1 << i) != 0)
			i++;
		if (i == K) die(Mem.cstr("hxmc: scoped memory: more than 15 growable values (Grow, Pool) live at once\n"));
		var s = stack(t, i);
		if (Mem.getPtr(s, BASE).isNull()) open(t, i);
		owned = o | (1 << i);
		return i;
	}

	// the base and the end of stack i (claimed): its base is fresh memory of
	// the scope that claimed it, for the root checker
	@:hxmc.unsafe @:hxmc.alloc public static function base(i:Int):Ptr
		return Mem.getPtr(stack(table, i), BASE);

	public static inline function end(i:Int):Ptr
		return Mem.getPtr(stack(table, i), END);

	// ---- scopes: a mark is top0 and owned, read by the lowering (FnLower.mark),
	// which resets to it (top0 set back; release when owned is not the mask)

	// the stacks claimed since the mark released (@:keep: FnLower.reset calls it)
	@:keep @:hxmc.unsafe public static function release(mask:Int) {
		var t = table, released = owned & ~mask;
		for (i in 1...K)
			if (released & (1 << i) != 0) {
				var si = stack(t, i);
				Mem.setPtr(si, TOP, Mem.getPtr(si, BASE));
			}
		owned = mask;
	}

	// (a compiler built before the marks were variables calls these: kept
	// so that it builds this std)
	@:keep @:hxmc.unsafe public static function markTop():Ptr
		return top0;

	@:keep @:hxmc.unsafe public static function markMask():Int
		return owned;

	@:keep @:hxmc.unsafe public static function reset(top:Ptr, mask:Int) {
		if (owned != mask) release(mask);
		top0 = top;
	}

	// the bytes in use on the fixed stack, and the stacks claimed (tests, reports)
	@:hxmc.unsafe public static function used():Int {
		var p = top0;
		return p.isNull() ? 0 : p.diff(base0).toInt();
	}

	@:hxmc.unsafe public static function claimed():Int {
		var n = 0, o = owned;
		for (i in 1...K)
			if (o & (1 << i) != 0) n++;
		return n;
	}

	// ---- failures: scoped code cannot throw

	@:hxmc.unsafe @:hxmc.noReturn public static function overflow()
		Abort.die("hxmc: scoped memory: a data stack is full (RT_DATA_STACK_MB on wasm32)\n");

	static inline function die(msg:Ptr)
		Abort.dieC(msg);

	#if (hxmc.target != "wasm32-wasi")
	// a thread ends: its stacks and table released (Threads, through dataStacksExit)
	@:hxmc.callback @:hxmc.unsafe static function threadExit(_:Ptr):Ptr {
		var t = table;
		if (t.isNull()) return t;
		for (i in 0...K) {
			var b:Ptr = Mem.getPtr(stack(t, i), BASE);
			if (!b.isNull()) Os.release(b, (RESERVE : I64) * 8);
		}
		LibC.free(t);
		table = Ptr.nil();
		top0 = Ptr.nil();
		base0 = Ptr.nil();
		end0 = Ptr.nil();
		owned = 0;
		return table;
	}
	#end
}
