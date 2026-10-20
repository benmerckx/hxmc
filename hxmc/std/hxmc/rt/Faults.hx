package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.*;

// Null access on the native targets (docs/hxmc.md, "Null access"): typed
// code reads and writes through a reference without testing it, and a null
// one faults near address 0 (an object's fields are at small offsets from
// its address, its header just below it). A fault handler (POSIX: SIGSEGV
// and SIGBUS, with SA_SIGINFO; Windows: a vectored exception handler) turns
// such a fault of the program's code into a throw: it changes the
// interrupted context so that, once the handler returns, the thread runs
// rt_null_access as if the faulting instruction had called it, and that
// throws "Null Access" as any throw does (rt_throw: longjmp to the innermost
// try's handler, which restores the shadow stack). Nothing runs in the
// signal handler itself but a few loads and stores: the throw runs on the
// thread's own stack in its normal state (the signal mask restored by the
// kernel, the collector's handshake as at any other instruction).
//
// A fault is a null access when it is a fault of the hardware (not a signal
// sent by a process), its address is within NEAR of 0 (either side), its
// instruction is in the program's code (the image, or code registered with
// addCode: native macros), the thread is one of the runtime's, running
// (not in a blocking call's safe region), not collecting, and the innermost
// handler is plausible (null: uncaught, or above the faulting frame). Any
// other fault goes to the handler that was there before (the default: the
// process dies of the signal, as without this handler). RT_NULL_ACCESS=0
// installs nothing.
@:hxmc.native @:keep @:allow(hxmc.rt)
class Faults {
	// the null page and its neighbours: Linux never maps the first 64 KB
	// (vm.mmap_min_addr), Windows reserves them, macOS maps nothing below 4 GB;
	// below 0: an object's header (its type index at -4)
	static inline var NEAR = 65536;

	// the image's code [lo, hi) (ELF: the whole image; Mach-O: __TEXT; PE: the image)
	static var codeLo:Ptr;
	static var codeHi:Ptr;
	// code mapped at run time (native macros: hxmc.macro.Loader): [lo, hi) pairs,
	// the count stored after the pair (a handler on another thread reads them)
	static inline var MAX_EXTRA = 64;
	static var extra:Ptr;
	@:hxmc.export("hxmc_faults_nextra") static var nextra:Int;
	// POSIX: the actions installed before (struct sigaction, SA_BYTES each), SIGSEGV's then SIGBUS's
	static var prev:Ptr;
	static var installed:Bool;
	// Linux with glibc (-D hxmc.libc=glibc): raise, found once (dlsym), to send a
	// signal that a process sent on with the action restored
	static var raiseFn:Ptr;
	// Windows: the vectored handler
	static var veh:Ptr;

	@:hxmc.noGc static inline function windows():Bool
		return Mem.os() == 2;

	// struct sigaction: Linux (musl, glibc) 152 bytes, the handler at 0, the
	// mask at 8, the flags at 136; Bionic (LP64) the flags at 0, the handler
	// at 8, the mask at 16 (32 bytes); macOS the handler at 0, the mask at 8,
	// the flags at 12 (16 bytes)
	static var SA_BYTES(get, never):Int;

	@:hxmc.noGc static inline function get_SA_BYTES():Int
		return Mem.os() == 1 ? 16 : Mem.target() >= 9 ? 32 : 152;

	static var SA_HANDLER(get, never):Int;

	@:hxmc.noGc static inline function get_SA_HANDLER():Int
		return Mem.target() >= 9 ? 8 : 0;

	static var SA_FLAGS(get, never):Int;

	@:hxmc.noGc static inline function get_SA_FLAGS():Int
		return Mem.os() == 1 ? 12 : Mem.target() >= 9 ? 0 : 136;

	static var SA_SIGINFO(get, never):Int;

	@:hxmc.noGc static inline function get_SA_SIGINFO():Int
		return Mem.os() == 1 ? 0x40 : 4;

	static var SIGBUS(get, never):Int;

	@:hxmc.noGc static inline function get_SIGBUS():Int
		return Mem.os() == 1 ? 10 : 7;

	static inline var SIGSEGV = 11;

	// siginfo_t: si_code at 8, si_addr at 16 (Linux) or 24 (macOS)
	static var SI_ADDR(get, never):Int;

	@:hxmc.noGc static inline function get_SI_ADDR():Int
		return Mem.os() == 1 ? 24 : 16;

	// from rt_init (Start), once the collector and the threads are set up
	@:hxmc.noGc static function init() {
		var off = Os.getenv("RT_NULL_ACCESS");
		if (!off.isNull() && Mem.getU8(off, 0) == "0".code) return;
		imageCode();
		extra = LibC.malloc(16 * MAX_EXTRA);
		// (one target's branch is lowered: Lower folds Mem.os())
		if (windows()) {
			// first: before the runtime's own handlers (WinRt: commits, crash reports)
			veh = K.AddVectoredExceptionHandler(1, Callback.addr(onException));
			installed = !veh.isNull();
		} else {
			if (Mem.target() == 7 || Mem.target() == 8) raiseFn = S.dlsym(Ptr.nil(), Mem.cstr("raise")); // (RTLD_DEFAULT)
			var n = SA_BYTES;
			prev = LibC.malloc(2 * n);
			LibC.memset(prev, 0, 2 * n);
			var act = Mem.stack(160);
			LibC.memset(act, 0, n); // (an empty mask: the handler blocks only its own signal)
			Mem.setPtr(act, SA_HANDLER, Callback.addr(onSignal));
			Mem.setI32(act, SA_FLAGS, SA_SIGINFO);
			if (S.sigaction(SIGSEGV, act, prev) == 0) {
				S.sigaction(SIGBUS, act, prev.add(n));
				installed = true;
			}
		}
	}

	// a shared library's runtime that ends (Gc.releaseHeap): the actions
	// before it are back, where its own are still installed
	@:hxmc.noGc static function uninstall() {
		if (windows()) {} else if (installed) {
			installed = false;
			var n = SA_BYTES;
			var cur = Mem.stack(160);
			for (k in 0...2) {
				var sig = k == 0 ? SIGSEGV : SIGBUS;
				if (S.sigaction(sig, Ptr.nil(), cur) == 0 && Mem.getPtr(cur, SA_HANDLER) == Callback.addr(onSignal))
					S.sigaction(sig, prev.add(k * n), Ptr.nil());
			}
		}
	}

	// code mapped at run time (native macros register theirs; one thread at a time)
	@:hxmc.noGc public static function addCode(lo:Ptr, hi:Ptr) {
		var n = nextra;
		if (extra.isNull() || n == MAX_EXTRA) return;
		Mem.setPtr(extra, 16 * n, lo);
		Mem.setPtr(extra, 16 * n + 8, hi);
		Atomic.store32(Mem.sym("hxmc_faults_nextra"), n + 1);
	}

	@:hxmc.noGc static function imageCode() {
		if (Mem.os() == 1) {
			// the Mach-O image holding this code (an executable or a dylib): its
			// header starts __TEXT, whose size its load command gives
			var info = Mem.stack(32); // Dl_info: dli_fbase at 8
			if (S.dladdr(Mem.sym("rt_null_access"), info) == 0) return;
			var h = Mem.getPtr(info, 8);
			var ncmds = Mem.getI32(h, 16);
			var c = h.add(32); // (mach_header_64)
			for (_ in 0...ncmds) {
				// LC_SEGMENT_64: the name at 8, vmsize at 32
				if (Mem.getI32(c, 0) == 0x19 && Mem.getI32(c, 8) == 0x45545f5f && Mem.getI32(c, 12) == 0x5458 && Mem.getI32(c, 16) == 0) {
					codeLo = h;
					codeHi = h.addL(Mem.getI64(c, 32));
					return;
				}
				c = c.add(Mem.getI32(c, 4));
			}
		} else if (Mem.os() == 2) {
			// the executable's image: SizeOfImage in its optional header (PE32+)
			var base = K.GetModuleHandleA(Ptr.nil());
			var pe = base.add(Mem.getI32(base, 0x3C));
			codeLo = base;
			codeHi = base.add(Mem.getI32(pe, 24 + 56));
		} else {
			// ELF: the image the linker laid out (code and data; an address of
			// code is never in the data)
			codeLo = Mem.sym("__ehdr_start");
			codeHi = Mem.sym("_end");
		}
	}

	@:hxmc.noGc static function inCode(pc:Ptr):Bool {
		if (!pc.ult(codeLo) && pc.ult(codeHi)) return true;
		for (i in 0...Atomic.load32(Mem.sym("hxmc_faults_nextra")))
			if (!pc.ult(Mem.getPtr(extra, 16 * i)) && pc.ult(Mem.getPtr(extra, 16 * i + 8))) return true;
		return false;
	}

	@:hxmc.noGc static inline function near(a:Ptr):Bool
		return Mem.ult(a.toI64() + NEAR, 2 * NEAR);

	// whether this fault becomes a throw: the thread is one of the runtime's,
	// running Haxe code (not in a safe region, where it holds no heap address
	// and may not run any; not collecting), and its innermost handler, when
	// there is one, is a frame above this one (a handler that is not would
	// fault again in the longjmp)
	@:hxmc.noGc static function throwable(pc:Ptr, a:Ptr, sp:Ptr):Bool {
		if (!near(a) || !inCode(pc)) return false;
		var m = Threads.self;
		if (m.isNull() || Threads.stateOf(m) != Threads.RUNNING || Threads.collector == m) return false;
		var h = Gc.hcur;
		return h.isNull() || !h.ult(sp); // (a frame slot: at or above the stack pointer)
	}

	// the thread goes on in rt_null_access, called by the faulting instruction:
	// x86-64, its address pushed as the return address (System V: the
	// signal frame lies below the red zone, which this word is in; Windows:
	// below the 32 bytes the callee may use, in the exception frame's top
	// part, which the dispatcher no longer needs: as Go does); arm64: in the
	// link register. The stack pointer 16-byte aligned as at a call.
	@:hxmc.noGc static function redirect(ctx:Ptr, pcOff:Int, spOff:Int, lrOff:Int) {
		var pc = Mem.getPtr(ctx, pcOff);
		var sp = Mem.getI64(ctx, spOff) & ~(15 : I64);
		if (Mem.arm()) {
			Mem.setI64(ctx, spOff, sp);
			Mem.setPtr(ctx, lrOff, pc);
		} else {
			if (windows()) sp -= 32;
			sp -= 8;
			Mem.setPtr(Ptr.ofI64(sp), 0, pc);
			Mem.setI64(ctx, spOff, sp);
		}
		Mem.setPtr(ctx, pcOff, Mem.sym("rt_null_access"));
	}

	// ucontext_t: the program counter, stack pointer and link register
	// (Linux and Android: in uc_mcontext; macOS: in the thread state behind
	// the uc_mcontext pointer at 48, past its 16 bytes of exception state)
	@:hxmc.callback @:hxmc.noGc static function onSignal(sig:Int, info:Ptr, uc:Ptr):Void {
		var code = Mem.getI32(info, 8);
		var a = Mem.getPtr(info, SI_ADDR);
		var ctx = Mem.os() == 1 ? Mem.getPtr(uc, 48) : uc;
		var pcOff = Mem.os() == 1 ? (Mem.arm() ? 272 : 144) : (Mem.arm() ? 440 : 168);
		var spOff = Mem.os() == 1 ? (Mem.arm() ? 264 : 72) : (Mem.arm() ? 432 : 160);
		var lrOff = Mem.os() == 1 ? 256 : 424;
		// (si_code: positive for the kernel's faults; 0 and below when a
		// process sent it; Linux's SI_KERNEL 0x80, a general protection fault,
		// has no address)
		if (code > 0 && code < 0x80 && throwable(Mem.getPtr(ctx, pcOff), a, Mem.getPtr(ctx, spOff))) {
			redirect(ctx, pcOff, spOff, lrOff);
			return;
		}
		chain(sig, info, uc, code);
	}

	// another fault: the action before ours. Its handler is called; the
	// default (or ignoring it) is restored, and the fault happens again when
	// the handler returns, now with it (a signal a process sent is sent again)
	@:hxmc.noGc static function chain(sig:Int, info:Ptr, uc:Ptr, code:Int) {
		var p = prev.add(sig == SIGSEGV ? 0 : SA_BYTES);
		var h = Mem.getPtr(p, SA_HANDLER);
		if (Mem.ult(h.toI64(), 2)) { // SIG_DFL, SIG_IGN
			S.sigaction(sig, p, Ptr.nil());
			installed = false;
			if (code <= 0) {
				if (Mem.target() == 7 || Mem.target() == 8) {
					if (!raiseFn.isNull()) Ind.call1(raiseFn, sig);
				} else S.raise(sig);
			}
			return;
		}
		if (Mem.getI32(p, SA_FLAGS) & SA_SIGINFO != 0) Ind.call3(h, sig, info, uc) else Ind.call1(h, sig);
	}

	// EXCEPTION_POINTERS: the record at 0, the context at 8; EXCEPTION_RECORD:
	// the code at 0, NumberParameters at 24, the access's address at 40;
	// CONTEXT: x86-64 Rsp at 152 and Rip at 248; arm64 Lr at 248, Sp at 256, Pc at 264
	@:hxmc.callback @:hxmc.noGc static function onException(e:Ptr):Int {
		var r = Mem.getPtr(e, 0);
		if (Mem.getI32(r, 0) != 0xC0000005 || Mem.getI32(r, 24) < 2) return 0; // EXCEPTION_ACCESS_VIOLATION; EXCEPTION_CONTINUE_SEARCH
		var ctx = Mem.getPtr(e, 8);
		var pcOff = Mem.arm() ? 264 : 248, spOff = Mem.arm() ? 256 : 152;
		if (!throwable(Mem.getPtr(ctx, pcOff), Mem.getPtr(r, 40), Mem.getPtr(ctx, spOff))) return 0;
		redirect(ctx, pcOff, spOff, 248);
		return -1; // EXCEPTION_CONTINUE_EXECUTION
	}
}

@:hxmc.c @:hxmc.fast private extern class S {
	static function sigaction(sig:Int, act:Ptr, old:Ptr):Int;
	static function raise(sig:Int):Int;
	static function dladdr(addr:Ptr, info:Ptr):Int; // (macOS)
	static function dlsym(handle:Ptr, name:Ptr):Ptr; // (glibc)
}

@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call1(f:Ptr, sig:Int):Void;
	@:hxmc.indirect static function call3(f:Ptr, sig:Int, info:Ptr, uc:Ptr):Void;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") private extern class K {
	static function AddVectoredExceptionHandler(first:Int, handler:Ptr):Ptr;
	static function GetModuleHandleA(name:Ptr):Ptr;
}
