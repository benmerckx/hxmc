package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Layouts as L;
import hxmc.unsafe.*;

// The Windows host layer of the runtime (once hxmc/c/rt_win.c and the
// crash handler of rthxmc.c), called by the runtime's Haxe code.
//
// Memory: the collector reserves large ranges (heap regions, the shadow
// stack) and relies on pages being committed as they are touched
// (MAP_NORESERVE elsewhere). Windows commits explicitly, so rt_win_reserve
// reserves address space and registers the range: a vectored exception
// handler commits the pages of a registered range on their first access (in
// chunks), and rt_win_decommit gives them back. A guard is a part of a range
// that is never committed. The handler and everything it calls are no-GC
// functions: they run on any thread, at any instruction.
@:hxmc.os("windows") @:keep @:allow(hxmc.rt)
class WinRt {
	static inline var MAX_RANGES = 256;
	// a range: start, end ([start, end), 0 when free), guard start, guard end
	static inline var RANGE = 32;
	// committed per fault: a large heap region in large chunks, stacks in small ones
	static inline var CHUNK_MIN = 64 << 10;
	static inline var CHUNK_MAX = 4 << 20;

	static inline var MEM_COMMIT = 0x1000;
	static inline var MEM_RESERVE = 0x2000;
	static inline var MEM_DECOMMIT = 0x4000;
	static inline var MEM_RELEASE = 0x8000;
	static inline var PAGE_READWRITE = 4;
	static inline var EXCEPTION_ACCESS_VIOLATION = 0xC0000005;
	static inline var EXCEPTION_CONTINUE_EXECUTION = -1;
	static inline var EXCEPTION_CONTINUE_SEARCH = 0;
	static inline var CP_UTF8 = 65001;

	// the SRW lock (8 bytes), then the ranges: allocated by the first
	// reservation (rt_init, before any other thread)
	static var table:Ptr;
	static var pageSize:Int;
	static var socketsReady:Bool;

	@:hxmc.host("rt_win_page_size") @:hxmc.unsafe static function rtPageSize():I64 {
		if (pageSize == 0) {
			var si = Mem.stack(64); // SYSTEM_INFO: dwPageSize at 4
			K.GetSystemInfo(si);
			pageSize = Mem.getI32(si, 4);
		}
		return pageSize;
	}

	@:hxmc.unsafe static inline function lockOf():Ptr
		return table;

	@:hxmc.unsafe static inline function range(i:Int):Ptr
		return table.add(8 + RANGE * i);

	@:hxmc.unsafe static function findRange(a:Ptr):Ptr {
		for (i in 0...MAX_RANGES) {
			var r = range(i);
			var s = Mem.getPtr(r, 0);
			if (!s.isNull() && !a.ult(s) && a.ult(Mem.getPtr(r, 8))) return r;
		}
		return Ptr.nil();
	}

	// commits the chunk around a in r (the caller holds the lock, shared)
	@:hxmc.unsafe static function commitAt(r:Ptr, a:Ptr):Bool {
		var start = Mem.getPtr(r, 0), end = Mem.getPtr(r, 8);
		var gs = Mem.getPtr(r, 16), ge = Mem.getPtr(r, 24);
		if (!a.ult(gs) && a.ult(ge)) return false;
		var size = end.diff(start);
		var chunk = size / 64;
		if (chunk < CHUNK_MIN) chunk = CHUNK_MIN;
		if (chunk > CHUNK_MAX) chunk = CHUNK_MAX;
		var lo = start.addL((a.diff(start) / chunk) * chunk);
		var hi = lo.addL(chunk);
		if (end.ult(hi)) hi = end;
		// not into the guard
		if (gs.ult(ge)) {
			if (!gs.ult(lo) && gs.ult(hi) && a.ult(gs)) hi = gs;
			if (lo.ult(ge) && !hi.ult(ge) && !a.ult(ge)) lo = ge;
		}
		return !K.VirtualAlloc(lo, hi.diff(lo), MEM_COMMIT, PAGE_READWRITE).isNull();
	}

	// EXCEPTION_POINTERS: the record at 0; EXCEPTION_RECORD: the code at 0,
	// NumberParameters at 24, ExceptionInformation at 32
	@:hxmc.callback @:hxmc.unsafe static function commitHandler(e:Ptr):Int {
		var r = Mem.getPtr(e, 0);
		if (Mem.getI32(r, 0) != EXCEPTION_ACCESS_VIOLATION || Mem.getI32(r, 24) < 2) return EXCEPTION_CONTINUE_SEARCH;
		var a = Mem.getPtr(r, 40);
		K.AcquireSRWLockShared(lockOf());
		var w = findRange(a);
		var ok = !w.isNull() && commitAt(w, a);
		K.ReleaseSRWLockShared(lockOf());
		return ok ? EXCEPTION_CONTINUE_EXECUTION : EXCEPTION_CONTINUE_SEARCH;
	}

	@:hxmc.host("rt_win_reserve") @:hxmc.unsafe static function reserve(bytes:I64):Ptr {
		var p = K.VirtualAlloc(Ptr.nil(), bytes, MEM_RESERVE, PAGE_READWRITE);
		if (p.isNull()) return p;
		if (table.isNull()) {
			var size:I64 = 8 + RANGE * MAX_RANGES;
			var t = LibC.malloc(size);
			LibC.memset(t, 0, size);
			table = t;
			K.AddVectoredExceptionHandler(1, Callback.addr(commitHandler));
		}
		K.AcquireSRWLockExclusive(lockOf());
		var i = 0;
		while (i < MAX_RANGES && !Mem.getPtr(range(i), 0).isNull())
			i++;
		if (i == MAX_RANGES) {
			K.ReleaseSRWLockExclusive(lockOf());
			K.VirtualFree(p, 0, MEM_RELEASE);
			return Ptr.nil();
		}
		var r = range(i);
		Mem.setPtr(r, 0, p);
		Mem.setPtr(r, 8, p.addL(bytes));
		Mem.setPtr(r, 16, Ptr.nil());
		Mem.setPtr(r, 24, Ptr.nil());
		K.ReleaseSRWLockExclusive(lockOf());
		return p;
	}

	@:hxmc.host("rt_win_release") @:hxmc.unsafe static function release(p:Ptr, bytes:I64):Void {
		K.AcquireSRWLockExclusive(lockOf());
		var r = findRange(p);
		if (!r.isNull()) {
			Mem.setPtr(r, 0, Ptr.nil());
			Mem.setPtr(r, 8, Ptr.nil());
		}
		K.ReleaseSRWLockExclusive(lockOf());
		K.VirtualFree(p, 0, MEM_RELEASE);
	}

	@:hxmc.host("rt_win_guard") @:hxmc.unsafe static function guard(p:Ptr, bytes:I64):Void {
		K.AcquireSRWLockExclusive(lockOf());
		var r = findRange(p);
		if (!r.isNull()) {
			Mem.setPtr(r, 16, p);
			Mem.setPtr(r, 24, p.addL(bytes));
		}
		K.ReleaseSRWLockExclusive(lockOf());
		K.VirtualFree(p, bytes, MEM_DECOMMIT);
	}

	@:hxmc.host("rt_win_decommit") @:hxmc.unsafe static function decommit(p:Ptr, bytes:I64):Void {
		if (bytes != (0 : I64)) K.VirtualFree(p, bytes, MEM_DECOMMIT);
	}

	// a malloc'ed UTF-8 copy of a wide string (invalid sequences become U+FFFD)
	@:hxmc.host("rt_win_utf8") @:hxmc.unsafe static function utf8(w:Ptr):Ptr {
		var n = K.WideCharToMultiByte(CP_UTF8, 0, w, -1, Ptr.nil(), 0, Ptr.nil(), Ptr.nil());
		var s = LibC.malloc((n > 0 ? n : 1 : I64));
		if (n <= 0 || K.WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, Ptr.nil(), Ptr.nil()) == 0) Mem.setI8(s, 0, 0);
		return s;
	}

	// a Winsock error as the errno OCaml's Unix library reports (unixsupport_win32.c)
	@:hxmc.host("rt_win_sock_errno") @:hxmc.unsafe static function sockErrno(wsa:Int):Int
		return L.wsaErrno(wsa);

	// a Win32 error as the errno OCaml's runtime maps it to (caml_win32_maperr)
	@:hxmc.unsafe public static function errnoOf(err:Int):Int
		return L.winErrno(err);

	// WSAStartup, once (two threads racing call it twice: it counts)
	@:hxmc.host("rt_win_sockets_init") @:hxmc.unsafe static function socketsInit():Void {
		if (socketsReady) return;
		var d = Mem.stack(512); // WSADATA
		Ws.WSAStartup(0x0202, d);
		socketsReady = true;
	}

	// ---- startup (rt_init): a crash names its exception and the address in
	// the image (the image has no unwind information for generated code, so
	// neither a debugger's stack trace nor an unhandled-exception filter can
	// be relied on); HXMC_TRACE reports the start

	@:hxmc.host("rt_win_init") @:hxmc.unsafe static function init():Void {
		K.AddVectoredExceptionHandler(0, Callback.addr(crash));
		var v = Mem.stack(16);
		var name = Mem.stack(16);
		var s = "HXMC_TRACE";
		for (i in 0...s.length)
			Mem.setI8(name, i, StringTools.fastCodeAt(s, i));
		Mem.setI8(name, s.length, 0);
		if (K.GetEnvironmentVariableA(name, v, 4) > 0) say("hxmc: started\n");
	}

	@:hxmc.unsafe static function say(msg:String) {
		var buf = Mem.stack(64);
		for (i in 0...msg.length)
			Mem.setI8(buf, i, StringTools.fastCodeAt(msg, i));
		var n = Mem.stack(16);
		K.WriteFile(K.GetStdHandle(-12), buf, msg.length, n, Ptr.nil()); // STD_ERROR_HANDLE
	}

	@:hxmc.unsafe static function hex(p:Ptr, at:Int, v:I64, n:Int) {
		var i = n - 1;
		while (i >= 0) {
			var d = (v & 15).toInt();
			Mem.setI8(p, at + i, d < 10 ? 48 + d : 87 + d);
			v = v >>> 4;
			i--;
		}
	}

	@:hxmc.callback @:hxmc.unsafe static function crash(e:Ptr):Int {
		var r = Mem.getPtr(e, 0);
		var c = Mem.getI32(r, 0);
		// access violation, illegal and privileged instruction, stack
		// overflow, division by zero, misalignment, in-page error, a stack
		// buffer overrun (0xC00000AA)
		if (c == EXCEPTION_ACCESS_VIOLATION || c == 0xC000001D || c == 0xC0000096 || c == 0xC00000FD || c == 0xC0000094 || c == 0x80000002
			|| c == 0xC0000006 || c == 0xC00000AA) {
			var a = Mem.getPtr(r, 16), base = K.GetModuleHandleA(Ptr.nil());
			var msg = "hxmc: exception 0x00000000 at image + 0x0000000000000000\n";
			var buf = Mem.stack(64);
			for (i in 0...msg.length)
				Mem.setI8(buf, i, StringTools.fastCodeAt(msg, i));
			hex(buf, 18, (c : I64) & 0xFFFFFFFF, 8);
			hex(buf, 40, a.diff(base), 16);
			var n = Mem.stack(16);
			K.WriteFile(K.GetStdHandle(-12), buf, msg.length, n, Ptr.nil());
		}
		return EXCEPTION_CONTINUE_SEARCH;
	}
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") private extern class K {
	static function GetSystemInfo(si:Ptr):Void;
	static function VirtualAlloc(p:Ptr, size:I64, type:Int, protect:Int):Ptr;
	static function VirtualFree(p:Ptr, size:I64, type:Int):Int;
	static function AddVectoredExceptionHandler(first:Int, handler:Ptr):Ptr;
	static function AcquireSRWLockShared(l:Ptr):Void;
	static function ReleaseSRWLockShared(l:Ptr):Void;
	static function AcquireSRWLockExclusive(l:Ptr):Void;
	static function ReleaseSRWLockExclusive(l:Ptr):Void;
	static function WideCharToMultiByte(cp:Int, flags:Int, w:Ptr, wn:Int, s:Ptr, n:Int, def:Ptr, used:Ptr):Int;
	static function GetEnvironmentVariableA(name:Ptr, buf:Ptr, n:Int):Int;
	static function GetStdHandle(which:Int):Ptr;
	static function WriteFile(h:Ptr, buf:Ptr, n:Int, written:Ptr, overlapped:Ptr):Int;
	static function GetModuleHandleA(name:Ptr):Ptr;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("ws2_32") private extern class Ws {
	static function WSAStartup(version:Int, data:Ptr):Int;
}
