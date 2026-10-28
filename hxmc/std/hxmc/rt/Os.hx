package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Layouts as L;
import hxmc.rt.C;
import hxmc.unsafe.*;

// The system layer of the native runtime's collector and threads (Gc,
// Threads): reserved memory committed as it is touched (Windows: WinRt's
// reservations), mutexes and condition variables in memory the caller
// provides (pthreads; Windows: SRW locks and condition variables), detached
// threads, time, the environment, errno, poll, the runtime's own reports.
// Every function is no-GC: the collector calls them while objects move, and
// threads call them where they hold no heap address. The C structures are
// opaque memory of the target's sizes (Layouts, read from the headers).
@:hxmc.native
class Os {
	static inline function windows():Bool
		return Mem.os() == 2;

	static inline function mac():Bool
		return Mem.os() == 1;

	// ---- the environment

	// getenv of a name (a string literal: a C string in the program's data; null: unset)
	public static inline function getenv(name:String):Ptr
		return C.getenv(Mem.cstr(name));

	public static inline function has(name:String):Bool
		return !getenv(name).isNull();

	// atoi of p: leading blanks, a sign, the digits
	@:hxmc.unsafe public static function atoi(p:Ptr):Int {
		var i = 0, neg = false, v = 0;
		while (true) {
			var c = Mem.getU8(p, i);
			if (c != " ".code && (c < 9 || c > 13)) break;
			i++;
		}
		if (Mem.getU8(p, i) == "-".code) {
			neg = true;
			i++;
		} else if (Mem.getU8(p, i) == "+".code)
			i++;
		while (true) {
			var c = Mem.getU8(p, i);
			if (c < "0".code || c > "9".code) break;
			v = v * 10 + (c - "0".code);
			i++;
		}
		return neg ? -v : v;
	}

	// atoi of an environment variable (a string literal), or def when it is unset
	public static inline function envInt(name:String, def:Int):Int
		return envIntC(Mem.cstr(name), def);

	@:hxmc.unsafe static function envIntC(name:Ptr, def:Int):Int {
		var p = C.getenv(name);
		return p.isNull() ? def : atoi(p);
	}

	// ---- errno (kept across the runtime's own calls around blocking natives)

	@:hxmc.unsafe static function errnoPtr():Ptr
		return windows() ? C._errno() : mac() ? C.__error() : Mem.target() >= 9 ? C.__errno() : C.__errno_location();

	@:hxmc.unsafe public static function errno():Int
		return Mem.getI32(errnoPtr(), 0);

	@:hxmc.unsafe public static function setErrno(e:Int)
		Mem.setI32(errnoPtr(), 0, e);

	// ---- time

	// seconds on the monotonic clock
	@:hxmc.unsafe public static function now():Float {
		var ts = Mem.stack(16);
		C.clock_gettime(L.CLOCK_MONOTONIC, ts);
		var s:Float = cast Mem.getI64(ts, 0);
		var ns:Float = Mem.getI32(ts, 8); // (tv_nsec: a long, 32 bits on Windows)
		return s + ns * 1e-9;
	}

	// (nanosleep, again after a signal; Windows: Sleep, in milliseconds as
	// WinSys.sleep's: MinGW-w64's nanosleep returned after 3-4 ms of 10 on
	// Windows on arm64)
	@:hxmc.unsafe public static function sleep(seconds:Float) {
		if (seconds <= 0) return;
		if (windows()) {
			hxmc.unsafe.Win32.Sleep(Std.int(seconds * 1000.0 + 0.5));
			return;
		}
		var t = Mem.stack(32);
		var whole = Math.ffloor(seconds);
		Mem.setI64(t, 0, (cast whole : I64));
		Mem.setI64(t, 8, (cast ((seconds - whole) * 1e9) : I64));
		while (C.nanosleep(t, t) != 0 && errno() == L.EINTR) {}
	}

	@:hxmc.unsafe public static function yield()
		if (windows()) K.SwitchToThread() else C.sched_yield();

	// ---- memory: reservations committed as touched (MAP_NORESERVE; Windows:
	// WinRt commits the pages of its reservations on first touch)

	static var pageBytes:Int;

	@:hxmc.unsafe public static function pageSize():Int {
		if (pageBytes == 0) pageBytes = windows() ? WinRt.rtPageSize().toInt() : C.sysconf(L.SC_PAGESIZE).toInt();
		return pageBytes;
	}

	// null on failure
	@:hxmc.unsafe public static function reserve(bytes:I64):Ptr {
		if (windows()) return WinRt.reserve(bytes);
		var p = C.mmap(Ptr.nil(), bytes, L.PROT_READ | L.PROT_WRITE, L.MAP_PRIVATE | L.MAP_ANONYMOUS | L.MAP_NORESERVE, -1, 0);
		return p.toI64() == -1 ? Ptr.nil() : p;
	}

	@:hxmc.unsafe public static function release(p:Ptr, bytes:I64)
		if (windows()) WinRt.release(p, bytes) else C.munmap(p, bytes);

	// never committed: an access faults
	@:hxmc.unsafe public static function guard(p:Ptr, bytes:I64)
		if (windows()) WinRt.guard(p, bytes) else C.mprotect(p, bytes, L.PROT_NONE);

	// the pages go back to the system (zeros when touched again); false: not done
	@:hxmc.unsafe public static function decommit(p:Ptr, bytes:I64):Bool {
		if (windows()) {
			WinRt.decommit(p, bytes);
			return true;
		}
		return C.madvise(p, bytes, L.MADV_DONTNEED) == 0;
	}

	// core dumps (Linux and Android): whether a core dump holds [p, p + bytes)
	// (on: the pages around it, off: the pages within it). The kernel dumps a
	// mapping whole once a page of it is touched, its untouched pages as
	// zeros, written out when the core goes through a pipe (systemd-coredump,
	// apport), so the runtime's reservations are left out but for what it
	// uses of them (docs/hxmc.md, "Core dumps")
	@:hxmc.unsafe public static function coreDump(p:Ptr, bytes:I64, on:Bool) {
		if (Mem.os() == 0) {
			var mask:I64 = (pageSize() : I64) - 1;
			var lo = p.toI64(), hi = lo + bytes;
			if (on) {
				lo -= lo & mask;
				hi += (mask + 1 - (hi & mask)) & mask;
			} else {
				lo += (mask + 1 - (lo & mask)) & mask;
				hi -= hi & mask;
			}
			if (lo < hi) C.madvise(Ptr.ofI64(lo), hi - lo, on ? 17 : 16); // MADV_DODUMP, MADV_DONTDUMP (every Linux architecture's)
		}
	}

	// a stack's reservation in a core dump: its STACK_DUMP bytes at the end
	// it grows from (a C stack's top, a shadow stack's bottom); a fault puts
	// back what the faulting thread's stacks hold (Faults.dumpStacks)
	public static inline var STACK_DUMP = 8 << 20;

	@:hxmc.unsafe public static function stackCoreDump(p:Ptr, bytes:I64, down:Bool) {
		if (bytes > (STACK_DUMP : I64)) coreDump(down ? p : p.add(STACK_DUMP), bytes - STACK_DUMP, false);
	}

	// transparent huge pages (Linux only: RT_HUGE)
	@:hxmc.unsafe public static function hugePages(p:Ptr, bytes:I64)
		if (Mem.os() == 0) C.madvise(p, bytes, L.MADV_HUGEPAGE);

	// ---- mutexes and conditions, in memory that never moves (malloc'ed or
	// static): MUTEX_BYTES and COND_BYTES each

	public static var MUTEX_BYTES(get, never):Int;

	static inline function get_MUTEX_BYTES():Int
		return windows() ? 8 : L.PTHREAD_MUTEX_SIZE;

	public static var COND_BYTES(get, never):Int;

	static inline function get_COND_BYTES():Int
		return windows() ? 8 : L.PTHREAD_COND_SIZE;

	static var monoAttr:Ptr; // conditions waiting on CLOCK_MONOTONIC (CLOCK_REALTIME on macOS)

	@:hxmc.unsafe public static function mutexInit(m:Ptr)
		if (windows()) Mem.setI64(m, 0, 0) else C.pthread_mutex_init(m, Ptr.nil()); // SRWLOCK_INIT

	@:hxmc.unsafe public static function mutexDestroy(m:Ptr)
		if (!windows()) C.pthread_mutex_destroy(m);

	@:hxmc.unsafe public static inline function lock(m:Ptr)
		if (windows()) K.AcquireSRWLockExclusive(m) else C.pthread_mutex_lock(m);

	@:hxmc.unsafe public static inline function tryLock(m:Ptr):Bool
		return windows() ? K.TryAcquireSRWLockExclusive(m) & 0xFF != 0 : C.pthread_mutex_trylock(m) == 0;

	@:hxmc.unsafe public static inline function unlock(m:Ptr)
		if (windows()) K.ReleaseSRWLockExclusive(m) else C.pthread_mutex_unlock(m);

	// a condition variable; monotonic: timed waits measure CLOCK_MONOTONIC
	// (the default clock otherwise, as PTHREAD_COND_INITIALIZER)
	@:hxmc.unsafe public static function condInit(c:Ptr, monotonic:Bool) {
		if (windows()) {
			Mem.setI64(c, 0, 0); // CONDITION_VARIABLE_INIT
			return;
		}
		if (!monotonic) {
			C.pthread_cond_init(c, Ptr.nil());
			return;
		}
		if (monoAttr.isNull()) {
			var a = LibC.malloc((L.PTHREAD_CONDATTR_SIZE : I64));
			C.pthread_condattr_init(a);
			if (!mac()) C.pthread_condattr_setclock(a, L.CLOCK_MONOTONIC);
			monoAttr = a;
		}
		C.pthread_cond_init(c, monoAttr);
	}

	@:hxmc.unsafe public static function condDestroy(c:Ptr)
		if (!windows()) C.pthread_cond_destroy(c);

	@:hxmc.unsafe public static function condWait(c:Ptr, m:Ptr)
		if (windows()) K.SleepConditionVariableSRW(c, m, -1, 0) else C.pthread_cond_wait(c, m);

	// a deadline `timeout` seconds from now for condTimedWait, in 16 bytes at
	// d: a timespec on the condition's clock (CLOCK_MONOTONIC; macOS has no
	// pthread_condattr_setclock: CLOCK_REALTIME)
	@:hxmc.unsafe public static function deadline(d:Ptr, timeout:Float) {
		C.clock_gettime(mac() ? L.CLOCK_REALTIME : L.CLOCK_MONOTONIC, d);
		var s:Float = cast Mem.getI64(d, 0);
		var ns:Float = Mem.getI32(d, 8);
		var t = s + ns * 1e-9 + timeout;
		var whole = Math.ffloor(t);
		var sec:I64 = cast whole;
		var nsec:I64 = cast ((t - whole) * 1e9);
		if (nsec >= 1000000000) {
			sec = sec + 1;
			nsec = nsec - 1000000000;
		}
		Mem.setI64(d, 0, sec);
		Mem.setI64(d, 8, nsec);
	}

	// false: timed out (Windows: the milliseconds left until the deadline)
	@:hxmc.unsafe public static function condTimedWait(c:Ptr, m:Ptr, d:Ptr):Bool {
		if (windows()) {
			var now = Mem.stack(16);
			C.clock_gettime(L.CLOCK_MONOTONIC, now);
			var left:Float = cast (Mem.getI64(d, 0) - Mem.getI64(now, 0));
			var nl:Float = Mem.getI32(d, 8) - Mem.getI32(now, 8);
			left += nl * 1e-9;
			var ms = left <= 0 ? 0 : left > 4e6 ? -294967296 : (cast (left * 1000.0 + 0.999) : Int);
			if (K.SleepConditionVariableSRW(c, m, ms, 0) != 0) return true;
			return K.GetLastError() != 1460; // ERROR_TIMEOUT
		}
		return C.pthread_cond_timedwait(c, m, d) != L.ETIMEDOUT;
	}

	@:hxmc.unsafe public static inline function signal(c:Ptr)
		if (windows()) K.WakeConditionVariable(c) else C.pthread_cond_signal(c);

	@:hxmc.unsafe public static inline function broadcast(c:Ptr)
		if (windows()) K.WakeAllConditionVariable(c) else C.pthread_cond_broadcast(c);

	// ---- threads

	// a detached thread running entry(arg) (a @:hxmc.callback taking and
	// returning a pointer) on a C stack of stackBytes (reserved, committed as
	// it grows); false: not started
	@:hxmc.unsafe public static function spawn(entry:Ptr, arg:Ptr, stackBytes:I64):Bool {
		if (windows()) {
			// STACK_SIZE_PARAM_IS_A_RESERVATION; not joined
			var h = K.CreateThread(Ptr.nil(), stackBytes, entry, arg, 0x10000, Ptr.nil());
			if (h.isNull()) return false;
			K.CloseHandle(h);
			return true;
		}
		var attr = Mem.stack(128);
		C.pthread_attr_init(attr);
		C.pthread_attr_setstacksize(attr, stackBytes);
		C.pthread_attr_setdetachstate(attr, L.PTHREAD_CREATE_DETACHED);
		var t = Mem.stack(16);
		var r = C.pthread_create(t, attr, entry, arg);
		C.pthread_attr_destroy(attr);
		return r == 0;
	}

	// ---- descriptors: poll (Windows: WSAPoll, sockets only)

	@:hxmc.unsafe public static function poll(fds:Ptr, n:Int, ms:Int):Int {
		if (windows()) {
			var r = W.WSAPoll(fds, n, ms);
			if (r < 0) setErrno(WinRt.sockErrno(W.WSAGetLastError()));
			return r;
		}
		return C.poll(fds, (n : I64), ms);
	}

	// ---- the end of the program

	// (Android: _exit, as PosixSys.exit; a moment first for what was
	// written to stderr to reach logcat, through hxmc.os's pipe)
	@:hxmc.unsafe @:hxmc.gcfree public static function exit(code:Int) {
		if (Mem.target() >= 9) {
			C.fflush(Ptr.nil());
			var ts = Mem.stack(16);
			Mem.setI64(ts, 0, 0);
			Mem.setI64(ts, 8, 200000000);
			C.nanosleep(ts, Ptr.nil());
			C._exit(code);
		} else C.exit(code);
	}

	// ---- the runtime's own reports on stderr (bytes as they are, after
	// whatever the C library's stdout buffers)

	@:hxmc.unsafe @:hxmc.gcfree public static function write(p:Ptr, n:Int) {
		C.fflush(Ptr.nil());
		if (windows()) C._write(2, p, n) else C.write(2, p, (n : I64));
	}
}

// a line of the runtime's reports, written into a frame area of
// Report.BYTES (no-GC: the collector reports while objects move), then to
// stderr: the length at 0, the text from 8 (@:hxmc.gcfree: a failed check
// of GC-free code reports with it, hxmc.SpanSupport)
abstract Report(Ptr) {
	public static inline var BYTES = 8 + 512;
	static inline var CAP = 512;

	public inline function new(p:Ptr) {
		this = p;
		Mem.setI32(p, 0, 0);
	}

	@:hxmc.unsafe @:hxmc.gcfree public function ch(c:Int) {
		var n = Mem.getI32(this, 0);
		if (n < CAP) Mem.setI8(this, 8 + n, c);
		Mem.setI32(this, 0, n + 1);
	}

	// a string literal (a C string in the program's data)
	public inline function str(s:String)
		cstr(Mem.cstr(s), 0, -1);

	// a C string, at least `width` wide (padded on the right, %-Ns), at most `max` (%.Ns)
	@:hxmc.unsafe @:hxmc.gcfree public function cstr(p:Ptr, width:Int, max:Int) {
		var k = 0;
		while (!p.isNull() && Mem.getU8(p, k) != 0 && (max < 0 || k < max)) {
			ch(Mem.getU8(p, k));
			k++;
		}
		while (k < width) {
			ch(" ".code);
			k++;
		}
	}

	// v in decimal, right-aligned in `width` (%Nld)
	@:hxmc.unsafe @:hxmc.gcfree public function int(v:I64, width:Int) {
		var tmp = Mem.stack(32);
		var k = 0, neg = v < 0;
		if (neg) v = -v;
		do {
			Mem.setI8(tmp, k++, 48 + (v % 10).toInt());
			v = v / 10;
		} while (!(v == 0));
		if (neg) Mem.setI8(tmp, k++, "-".code);
		var w = k;
		while (w < width) {
			ch(" ".code);
			w++;
		}
		while (k > 0)
			ch(Mem.getU8(tmp, --k));
	}

	// v with `decimals` digits after the point, right-aligned in `width`: printf's %N.Df
	@:hxmc.unsafe public function fixed(v:Float, decimals:Int, width:Int) {
		var tmp = Mem.stack(400);
		var k = FloatText.fixed(v, decimals, tmp);
		var w = k;
		while (w < width) {
			ch(" ".code);
			w++;
		}
		for (i in 0...k)
			ch(Mem.getU8(tmp, i));
	}

	// the line so far, to stderr
	@:hxmc.unsafe @:hxmc.gcfree public function flush() {
		var n = Mem.getI32(this, 0);
		Os.write(this.add(8), n < CAP ? n : CAP);
		Mem.setI32(this, 0, 0);
	}
}

// the C library (libc; Windows: the UCRT and MinGW-w64's clock_gettime)
@:hxmc.c @:hxmc.fast private extern class C {
	static function getenv(name:Ptr):Ptr;
	static function __errno_location():Ptr;
	static function __errno():Ptr; // (Bionic)
	static function __error():Ptr;
	static function _errno():Ptr;
	static function clock_gettime(clock:Int, ts:Ptr):Int;
	static function nanosleep(req:Ptr, rem:Ptr):Int;
	static function sched_yield():Int;
	static function sysconf(name:Int):I64;
	static function mmap(addr:Ptr, len:I64, prot:Int, flags:Int, fd:Int, off:I64):Ptr;
	static function munmap(addr:Ptr, len:I64):Int;
	static function mprotect(addr:Ptr, len:I64, prot:Int):Int;
	static function madvise(addr:Ptr, len:I64, advice:Int):Int;
	static function pthread_mutex_init(m:Ptr, attr:Ptr):Int;
	static function pthread_mutex_destroy(m:Ptr):Int;
	static function pthread_mutex_lock(m:Ptr):Int;
	static function pthread_mutex_trylock(m:Ptr):Int;
	static function pthread_mutex_unlock(m:Ptr):Int;
	static function pthread_condattr_init(a:Ptr):Int;
	static function pthread_condattr_setclock(a:Ptr, clock:Int):Int;
	static function pthread_cond_init(c:Ptr, attr:Ptr):Int;
	static function pthread_cond_destroy(c:Ptr):Int;
	static function pthread_cond_wait(c:Ptr, m:Ptr):Int;
	static function pthread_cond_timedwait(c:Ptr, m:Ptr, ts:Ptr):Int;
	static function pthread_cond_signal(c:Ptr):Int;
	static function pthread_cond_broadcast(c:Ptr):Int;
	static function pthread_attr_init(a:Ptr):Int;
	static function pthread_attr_destroy(a:Ptr):Int;
	static function pthread_attr_setstacksize(a:Ptr, size:I64):Int;
	static function pthread_attr_setdetachstate(a:Ptr, state:Int):Int;
	static function pthread_create(t:Ptr, attr:Ptr, entry:Ptr, arg:Ptr):Int;
	static function poll(fds:Ptr, n:I64, ms:Int):Int;
	static function exit(code:Int):Void;
	static function _exit(code:Int):Void;
	static function fflush(f:Ptr):Int;
	static function write(fd:Int, p:Ptr, n:I64):I64;
	static function _write(fd:Int, p:Ptr, n:Int):Int;
}

// Windows (kernel32)
@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") private extern class K {
	static function SwitchToThread():Int;
	static function AcquireSRWLockExclusive(l:Ptr):Void;
	static function TryAcquireSRWLockExclusive(l:Ptr):Int;
	static function ReleaseSRWLockExclusive(l:Ptr):Void;
	static function SleepConditionVariableSRW(c:Ptr, l:Ptr, ms:Int, flags:Int):Int;
	static function WakeConditionVariable(c:Ptr):Void;
	static function WakeAllConditionVariable(c:Ptr):Void;
	static function GetLastError():Int;
	static function CreateThread(sa:Ptr, stack:I64, entry:Ptr, arg:Ptr, flags:Int, id:Ptr):Ptr;
	static function CloseHandle(h:Ptr):Int;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("ws2_32") private extern class W {
	static function WSAPoll(fds:Ptr, n:Int, ms:Int):Int;
	static function WSAGetLastError():Int;
}
