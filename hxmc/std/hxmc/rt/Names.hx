package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The table of field names and the inline-cache misses (once hxmc/c/rt_dyn.c
// and wasm/Names.hx). The generated table (rt_field_names, sorted) is
// searched by bisection; names seen only at run time are appended, in
// malloc'ed chunks that never move (a reader needs no lock for a name it got
// an id for), with a hash table; adding, and searching the added names,
// holds a spin lock (held for a few instructions, never across a safepoint).
// Field names as Strings are immortal copies outside the heap, laid out like
// the string literals (the collector leaves both alone).
//
// Inline caches with several threads (rt_ic): a filled entry is never
// rewritten (a reader could see half of it); a miss on an entry filled for
// another type looks the field up into a per-thread table of immutable
// entries by (type, field id). Before the second thread starts, entries are
// refilled on each miss.
@:keep @:allow(hxmc.rt)
class Names {
	static inline var CHUNK = 1024;
	static inline var CHUNKS = 4096;
	static inline var IC_BUSY = 0xFFFFFFFF;
	static inline var IC_SIZE = 32; // rt_icache

	// Dyn.fid's cache of (hash, fid + 1) entries
	@:hxmc.bss(32768, "rt_fid_cache") public static var fidCache:Ptr;
	// spin locks of the runtime's Haxe code (int32): 0 PosixNet's resolver, 3 and 4 WinNet's, 8 this table
	@:hxmc.bss(64, "rt_spin") public static var spin:Ptr;
	// the added names: chunk pointers (CHUNKS), each CHUNK C strings
	@:hxmc.bss(32768) static var chunks:Ptr;
	static var nextra:Int;
	static var hash:Ptr; // int32 index + 1, open addressing
	static var hashCap:Int; // a power of two, at least twice nextra
	static var strs:Ptr; // fid -> immortal String
	static var strsCap:Int;

	// the running thread's table of inline-cache entries (keys: type << 32 | fid, 0 free)
	@:hxmc.threadLocal static var icKeys:Ptr;
	@:hxmc.threadLocal static var icVals:Ptr;
	@:hxmc.threadLocal static var icCap:Int;
	@:hxmc.threadLocal static var icN:Int;

	@:hxmc.unsafe static function multithreaded():Bool {
		if (Mem.os() == 3) return false;
		return Mem.getI32(Mem.sym("rt_mt"), 0) != 0;
	}

	@:hxmc.unsafe static function lock() {
		if (Mem.os() == 3) return;
		var l = spin.add(32);
		while (Atomic.cas32(l, 0, 1) != 0) {}
	}

	@:hxmc.unsafe static function unlock() {
		if (Mem.os() != 3) Atomic.store32(spin.add(32), 0);
	}

	static inline function nstatic():Int
		return Mem.getI32(Mem.sym("rt_nfield_names"), 0);

	static inline function staticName(i:Int):Ptr
		return Mem.getPtr(Mem.sym("rt_field_names"), 8 * i);

	@:hxmc.unsafe static inline function extraName(i:Int):Ptr
		return Mem.getPtr(Mem.getPtr(chunks, 8 * (i >> 10)), 8 * (i & (CHUNK - 1)));

	@:hxmc.unsafe static function findStatic(name:Ptr):Int {
		var lo = 0, hi = nstatic() - 1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			var c = LibC.strcmp(staticName(mid), name);
			if (c == 0) return mid;
			if (c < 0) lo = mid + 1 else hi = mid - 1;
		}
		return -1;
	}

	@:hxmc.unsafe static function nameHash(s:Ptr):Int {
		var h = 0x811c9dc5; // FNV-1a
		var i = 0;
		while (true) {
			var c = Mem.getU8(s, i);
			if (c == 0) return h;
			h = (h ^ c) * 16777619;
			i++;
		}
	}

	// (the lock held)
	@:hxmc.unsafe static function findExtra(name:Ptr):Int {
		if (hashCap == 0) return -1;
		var i = nameHash(name) & (hashCap - 1);
		while (true) {
			var e = Mem.getI32(hash, 4 * i);
			if (e == 0) return -1;
			if (LibC.strcmp(extraName(e - 1), name) == 0) return nstatic() + e - 1;
			i = (i + 1) & (hashCap - 1);
		}
	}

	@:hxmc.unsafe static function hashIn(i:Int) {
		var j = nameHash(extraName(i)) & (hashCap - 1);
		while (Mem.getI32(hash, 4 * j) != 0)
			j = (j + 1) & (hashCap - 1);
		Mem.setI32(hash, 4 * j, i + 1);
	}

	@:hxmc.unsafe static function strdup(s:Ptr):Ptr {
		var n = LibC.strlen(s) + 1;
		var p = LibC.malloc(n);
		LibC.memcpy(p, s, n);
		return p;
	}

	@:hxmc.unsafe static function intern(name:Ptr):Int {
		var f = findStatic(name);
		if (f >= 0) return f;
		lock();
		f = findExtra(name);
		if (f < 0) {
			if (nextra >= CHUNK * CHUNKS) {
				unlock();
				return -1;
			}
			var c = Mem.getPtr(chunks, 8 * (nextra >> 10));
			if (c.isNull()) {
				c = LibC.malloc(8 * CHUNK);
				Mem.setPtr(chunks, 8 * (nextra >> 10), c);
			}
			Mem.setPtr(c, 8 * (nextra & (CHUNK - 1)), strdup(name));
			f = nstatic() + nextra;
			nextra++;
			if (nextra * 2 > hashCap) {
				LibC.free(hash);
				hashCap = hashCap == 0 ? 1024 : hashCap * 2;
				var bytes:I64 = 4 * hashCap;
				hash = LibC.malloc(bytes);
				LibC.memset(hash, 0, bytes);
				for (i in 0...nextra)
					hashIn(i);
			} else
				hashIn(nextra - 1);
		}
		unlock();
		return f;
	}

	@:hxmc.host("hx_fid_c") @:hxmc.unsafe static function fidC(name:Ptr):Int {
		var f = findStatic(name);
		if (f >= 0) return f;
		lock();
		f = findExtra(name);
		unlock();
		return f;
	}

	@:hxmc.host("hx_fid_slow") @:hxmc.unsafe static function fidSlow(name:String):Int {
		var u = Str.toUtf8(name);
		var f = intern(u);
		LibC.free(u);
		return f;
	}

	// the id of a name if it has one (no interning): -1 otherwise
	@:hxmc.host("hx_fid_find") @:hxmc.unsafe static function fidFind(name:String):Int {
		var u = Str.toUtf8(name);
		var f = fidC(u);
		LibC.free(u);
		return f;
	}

	@:hxmc.host("hx_fid_name") @:hxmc.unsafe static function fidName(f:Int):Ptr
		return f < nstatic() ? staticName(f) : extraName(f - nstatic());

	@:hxmc.unsafe static function strOf(f:Int):Ptr {
		lock();
		var r = f < strsCap ? Mem.getPtr(strs, 8 * f) : Ptr.nil();
		unlock();
		return r;
	}

	// a field name as a String, made once
	@:hxmc.host("hx_fid_str") static function fidStr(f:Int):String {
		var r = strOf(f);
		if (!r.isNull()) return Mem.obj(r);
		var n = fidName(f);
		var s:String = Str.ofUtf8(n, LibC.strlen(n).toInt());
		return immortal(s, f);
	}

	@:hxmc.unsafe static function immortal(s:String, f:Int):String {
		var bytes:I64 = 8 + 8 * nslots(s);
		var copy = LibC.malloc(bytes);
		LibC.memcpy(copy, Mem.addr(s).add(-8), bytes);
		var r = copy.add(8);
		lock();
		if (f >= strsCap) {
			var ncap = strsCap == 0 ? 1024 : strsCap;
			while (ncap <= f)
				ncap *= 2;
			strs = LibC.realloc(strs, 8 * ncap);
			LibC.memset(strs.add(8 * strsCap), 0, 8 * (ncap - strsCap));
			strsCap = ncap;
		}
		var had = Mem.getPtr(strs, 8 * f);
		if (had.isNull()) Mem.setPtr(strs, 8 * f, r) else {
			LibC.free(copy);
			r = had;
		}
		unlock();
		return Mem.obj(r);
	}

	// ---- inline caches

	@:hxmc.unsafe static inline function slotOf(key:I64, cap:Int):Int
		return ((key * haxe.Int64.make(0x9E3779B9, 0x7F4A7C15)) >>> 32).toInt() & (cap - 1);

	@:hxmc.unsafe static function localGet(o:Dynamic, fid:Int):Ptr {
		var key = ((tindex(o) : I64) << 32) | ((fid : I64) & 0xFFFFFFFF);
		if (icN * 2 >= icCap) {
			var ncap = icCap == 0 ? 256 : icCap * 2;
			var nk = LibC.malloc(8 * ncap), nv = LibC.malloc(8 * ncap);
			LibC.memset(nk, 0, 8 * ncap);
			for (i in 0...icCap) {
				var k = Mem.getI64(icKeys, 8 * i);
				if (!(k == 0)) {
					var j = slotOf(k, ncap);
					while (!(Mem.getI64(nk, 8 * j) == 0))
						j = (j + 1) & (ncap - 1);
					Mem.setI64(nk, 8 * j, k);
					Mem.setPtr(nv, 8 * j, Mem.getPtr(icVals, 8 * i));
				}
			}
			LibC.free(icKeys);
			LibC.free(icVals);
			icKeys = nk;
			icVals = nv;
			icCap = ncap;
		}
		var j = slotOf(key, icCap);
		while (true) {
			var k = Mem.getI64(icKeys, 8 * j);
			if (k == 0) break;
			if (k == key) return Mem.getPtr(icVals, 8 * j);
			j = (j + 1) & (icCap - 1);
		}
		var e = LibC.malloc(IC_SIZE);
		Dyn.icacheFill(o, fid, e);
		Mem.setI32(e, 0, tindex(o));
		Mem.setI64(icKeys, 8 * j, key);
		Mem.setPtr(icVals, 8 * j, e);
		icN++;
		return e;
	}

	// a thread's end (Threads.exit): its entries go
	@:hxmc.host("rt_dyn_thread_exit") @:hxmc.unsafe static function threadExit():Void {
		for (i in 0...icCap)
			if (!(Mem.getI64(icKeys, 8 * i) == 0)) LibC.free(Mem.getPtr(icVals, 8 * i));
		LibC.free(icKeys);
		LibC.free(icVals);
		icKeys = Ptr.nil();
		icVals = Ptr.nil();
		icCap = 0;
		icN = 0;
	}

	@:hxmc.export("rt_icache_miss") @:hxmc.unsafe static function icacheMiss(o:Dynamic, fid:Int, c:Ptr):Ptr {
		if (multithreaded()) {
			if (Atomic.cas32(c, 0, IC_BUSY) == 0) {
				Dyn.icacheFill(o, fid, c);
				Atomic.store32(c, tindex(o));
				return c;
			}
			return localGet(o, fid);
		}
		Dyn.icacheFill(o, fid, c);
		Mem.setI32(c, 0, tindex(o));
		return c;
	}
}
