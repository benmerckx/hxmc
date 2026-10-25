package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.*;

// The data stacks of scoped memory (docs/plans/lowlevel.md, "Scoped
// memory"): per thread, up to K stacks, each a reservation with a bump
// pointer, made on first use. Stack 0 is the fixed one (what does not grow:
// a Str's copy, a Grow's header); a Grow or a Pool claims one of the others
// for itself alone (a bit in the owned mask), so its elements are always on
// top and growth never moves them. A scope marks (stack 0's top and the
// owned mask, two locals of the frame: FnLower) where it starts and resets
// where it ends: stack 0's top back, the stacks claimed since released
// (their tops back to their bases: a stack nobody owns is always empty
// above its base). Natively each stack reserves RESERVE bytes of address
// space, committed as touched (Os.reserve); on wasm32 it is a region of the
// linear memory (Heap.regionZero) of RT_DATA_STACK_MB megabytes (256 unless
// set). Running past a stack's end, or more Grows at once than stacks,
// aborts with a message: scoped code cannot throw.
//
// The table (malloc'ed, per thread): the owned mask (int32 at 0), then per
// stack its top, end and base (at 16 + 32 * i). No GC reference anywhere:
// the collector never scans or moves any of it.
@:allow(hxmc.scoped)
class DataStacks {
	public static inline var K = 16;
	static inline var TOP = 0;
	static inline var END = 8;
	static inline var BASE = 16;
	static inline var RESERVE:Int = 1 << 30; // (natively: 8 * this, below)

	@:hxmc.threadLocal static var table:Ptr;

	static inline function stack(t:Ptr, i:Int):Ptr
		return t.add(16 + 32 * i);

	// the table, made on first use
	static inline function tab():Ptr {
		var t = table;
		return t.isNull() ? init() : t;
	}

	@:hxmc.noGc static function init():Ptr {
		var bytes:I64 = 16 + 32 * K;
		var t = LibC.malloc(bytes);
		LibC.memset(t, 0, bytes);
		table = t;
		open(t, 0);
		#if (hxmc.target != "wasm32-wasi")
		Threads.dataStacksExit = Callback.addr(threadExit);
		#end
		return t;
	}

	// stack i reserved (its top at its base)
	@:hxmc.noGc static function open(t:Ptr, i:Int) {
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
	@:hxmc.noGc @:hxmc.alloc public static function alloc(bytes:Int):Ptr {
		var s = stack(tab(), 0);
		var p:Ptr = Mem.getPtr(s, TOP);
		var q = p.add((bytes + 7) & ~7);
		if (Mem.ult(Mem.getPtr(s, END).toI64(), q.toI64())) overflow();
		Mem.setPtr(s, TOP, q);
		return p;
	}

	// a copy of the units of s on the fixed stack (Str.copyOf: GC code)
	@:hxmc.noGc @:hxmc.alloc public static function copyString(s:String):Ptr {
		var n = Str.len(s);
		var p = alloc(2 * n);
		LibC.memcpy(p, Str.unitsAddr(s), (2 * n : I64));
		return p;
	}

	// a String of the n units at p (Str.toString: GC code)
	public static function stringOf(p:Ptr, n:Int):String {
		var r = Str.make(n);
		LibC.memcpy(Str.unitsAddr(r), p, (2 * n : I64));
		return r;
	}

	// a stack of its own for a Grow or a Pool: its index
	@:hxmc.noGc @:hxmc.alloc public static function claim():Int {
		var t = tab();
		var owned = Mem.getI32(t, 0);
		var i = 1;
		while (i < K && owned & (1 << i) != 0)
			i++;
		if (i == K) die(Mem.cstr("hxmc: scoped memory: more than 15 growable values (Grow, Pool) live at once\n"));
		var s = stack(t, i);
		if (Mem.getPtr(s, BASE).isNull()) open(t, i);
		Mem.setI32(t, 0, owned | (1 << i));
		return i;
	}

	// the base and the end of stack i (claimed): its base is fresh memory of
	// the scope that claimed it, for the root checker
	@:hxmc.noGc @:hxmc.alloc public static function base(i:Int):Ptr
		return Mem.getPtr(stack(table, i), BASE);

	public static inline function end(i:Int):Ptr
		return Mem.getPtr(stack(table, i), END);

	// ---- scopes: a mark is stack 0's top (null before the first use) and the owned mask

	@:hxmc.noGc public static function markTop():Ptr {
		var t = table;
		return t.isNull() ? Ptr.nil() : Mem.getPtr(stack(t, 0), TOP);
	}

	@:hxmc.noGc public static function markMask():Int {
		var t = table;
		return t.isNull() ? 0 : Mem.getI32(t, 0);
	}

	@:hxmc.noGc public static function reset(top:Ptr, mask:Int) {
		var t = table;
		if (t.isNull()) return;
		var s = stack(t, 0);
		Mem.setPtr(s, TOP, top.isNull() ? Mem.getPtr(s, BASE) : top);
		var owned = Mem.getI32(t, 0);
		if (owned != mask) {
			var released = owned & ~mask;
			for (i in 1...K)
				if (released & (1 << i) != 0) {
					var si = stack(t, i);
					Mem.setPtr(si, TOP, Mem.getPtr(si, BASE));
				}
			Mem.setI32(t, 0, mask);
		}
	}

	// the bytes in use on the fixed stack, and the stacks claimed (tests, reports)
	@:hxmc.noGc public static function used():Int {
		var t = table;
		if (t.isNull()) return 0;
		var s = stack(t, 0);
		return (Mem.getPtr(s, TOP).diff(Mem.getPtr(s, BASE))).toInt();
	}

	@:hxmc.noGc public static function claimed():Int {
		var t = table;
		if (t.isNull()) return 0;
		var n = 0, owned = Mem.getI32(t, 0);
		for (i in 1...K)
			if (owned & (1 << i) != 0) n++;
		return n;
	}

	// ---- failures: scoped code cannot throw

	@:hxmc.noGc @:hxmc.noReturn public static function overflow()
		Abort.die(Mem.cstr("hxmc: scoped memory: a data stack is full (RT_DATA_STACK_MB on wasm32)\n"));

	static inline function die(msg:Ptr)
		Abort.die(msg);

	#if (hxmc.target != "wasm32-wasi")
	// a thread ends: its stacks and table released (Threads, through dataStacksExit)
	@:hxmc.callback @:hxmc.noGc static function threadExit(_:Ptr):Ptr {
		var t = table;
		if (t.isNull()) return t;
		for (i in 0...K) {
			var b:Ptr = Mem.getPtr(stack(t, i), BASE);
			if (!b.isNull()) Os.release(b, (RESERVE : I64) * 8);
		}
		LibC.free(t);
		table = Ptr.nil();
		return table;
	}
	#end
}
