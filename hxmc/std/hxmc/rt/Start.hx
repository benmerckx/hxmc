package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Os.Report;
import hxmc.unsafe.*;

// The start of a native program and the end of an exception's unwinding
// (once hxmc/c/rt.c and rt_thread.c): the generated `main` (DataGen)
// calls rt_init, then rt_run_main with the program's body; generated code
// throws with rt_throw, which jumps to the innermost try's handler (setjmp
// in the try, longjmp here).
@:hxmc.native @:keep
class Start {
	@:hxmc.export("rt_argc") static var argc:Int;
	@:hxmc.export("rt_argv") static var argv:Ptr;
	// Android: the address of the C library's environ, taken here (a shared
	// library reaches a library's variable through its GOT slot, which the
	// linker can make of an address computation but not of a load)
	public static var environ:Ptr;

	@:hxmc.export("rt_init") @:hxmc.noGc static function init(ng:Int, ac:Int, av:Ptr):Void {
		if (Mem.os() == 2) {
			WinRt.init();
			// the arguments as UTF-8, from the UTF-16 command line (OCaml's
			// runtime on Windows does the same; main's argv is in the ANSI code
			// page); the standard streams carry bytes as they are (haxe.ml:
			// set_binary_mode_out; reads of descriptors are Unix.read's ReadFile,
			// without the C runtime's text mode)
			var n = Mem.stack(16);
			var w = Sh.CommandLineToArgvW(K.GetCommandLineW(), n);
			if (!w.isNull()) {
				var count = Mem.getI32(n, 0);
				var a = LibC.malloc(((count + 1) : I64) * 8);
				for (i in 0...count)
					Mem.setPtr(a, 8 * i, WinRt.utf8(Mem.getPtr(w, 8 * i)));
				Mem.setPtr(a, 8 * count, Ptr.nil());
				K.LocalFree(w);
				ac = count;
				av = a;
			}
			for (fd in 0...3)
				U._setmode(fd, 0x8000); // _O_BINARY
		}
		argc = ac;
		argv = av;
		if (Mem.target() >= 9) environ = Mem.sym("environ");
		var sbase = Gc.init(ng);
		Threads.init(sbase);
		var cap = ng #if hxmc.jit + Gc.SPARE_GLOBALS #end;
		var g = LibC.malloc(((cap + 1) : I64) * 8);
		LibC.memset(g, 0, ((cap + 1) : I64) * 8);
		Gc.globals = g;
		Gc.globalsCap = cap;
		Boxes.init(); // the static boxes
		// the type objects (rt_type_objs: two words each, DataGen)
		var nt = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		var to = Mem.sym("rt_type_objs");
		for (t in 0...nt) {
			Mem.setI64(to, 16 * t, Types.recordHdr(Types.T_TYPEOBJ, 1));
			Mem.setI32(to, 16 * t + 8, t);
		}
		// (Android: Bionic's atexit is crtbegin_so.o's, __cxa_atexit with the
		// library's handle; a glibc shared library registers none: a library
		// closed before the process exits (hxmc dev's host) would leave exit a
		// function to call that is gone, and glibc's dlclose runs a library's
		// __cxa_atexit functions only through its crtbegin's __cxa_finalize)
		#if hxmc.shared
		if (Mem.target() >= 9) U.__cxa_atexit(Callback.addr(Gc.report), Ptr.nil(), Mem.sym("__dso_handle"));
		#else
		if (Mem.target() >= 9) U.__cxa_atexit(Callback.addr(Gc.report), Ptr.nil(), Mem.sym("__dso_handle")) else U.atexit(Callback.addr(Gc.report));
		#end
		Faults.init(); // (null accesses throw)
	}

	// The program's main runs on a reserved stack of RT_STACK_MB (default
	// 1024) MB, committed as touched, with a guard page: OCaml 5, which the
	// reference compiler is built with, lets the main fiber's stack grow to 1
	// GB, and deep recursion in the port (the typer, Eval-interpreted code,
	// the hxmc regular expression engine) needs more than the default 8 MB
	// process stack. A stack switch (Mem.callOnStack); Windows: a fiber of
	// the main thread, whose stack is reserved at that size (committed as it
	// grows, with the system's guard page).
	static var mainFiber:Ptr;
	static var mainBody:Ptr;

	@:hxmc.export("rt_run_main") static function runMain(body:Ptr):Void {
		var bytes:I64 = (Os.envInt("RT_STACK_MB", 1024) : I64) << 20;
		if (Mem.os() == 2) {
			var fiber = Ptr.nil();
			if (!(bytes == 0)) {
				mainBody = body;
				mainFiber = K.ConvertThreadToFiber(Ptr.nil());
				if (!mainFiber.isNull()) fiber = K.CreateFiberEx(64 << 10, bytes, 1, Callback.addr(fiberMain), Ptr.nil()); // FIBER_FLAG_FLOAT_SWITCH
			}
			if (fiber.isNull()) {
				Mem.call0(body);
				return;
			}
			K.SwitchToFiber(fiber);
			return;
		}
		var stack = bytes == 0 ? Ptr.nil() : Os.reserve(bytes);
		if (stack.isNull()) {
			Mem.call0(body);
			return;
		}
		Os.guard(stack, Os.pageSize());
		Mem.callOnStack(stack.addL(bytes), body);
		#if hxmc.shared
		// (a library's program ended: its stack given back, as the library may be closed: hxmc dev's host)
		Os.release(stack, bytes);
		#end
	}

	// the main fiber's entry (Windows): the body, then back to the thread's
	// own fiber (the program's main returns)
	@:hxmc.callback static function fiberMain(arg:Ptr):Void {
		Mem.call0(mainBody);
		K.SwitchToFiber(mainFiber);
	}

	// ---- exceptions

	@:hxmc.export("rt_throw") static function throwValue(v:Dynamic):Void {
		Gc.exn = Mem.addr(v);
		var h = Gc.hcur;
		// (the thrower's stack up to the catch, when exception stacks are read: Stacks)
		Stacks.recordThrow(h);
		if (h.isNull()) {
			Gc.uncaught("Uncaught exception: ", v);
			// (where it was thrown, when the program has its table of lines)
			Stacks.report();
			Os.exit(1);
		}
		// the C library's longjmp without the signal mask (as the try's setjmp:
		// Abi.setjmp); MinGW's setjmp and longjmp without SEH unwinding
		if (Mem.target() == 5) J.__mingw_longjmp(h, 1) else if (Mem.os() == 2) J.longjmp(h, 1) else J._longjmp(h, 1);
	}
}

@:hxmc.c @:hxmc.fast private extern class J {
	static function _longjmp(buf:Ptr, v:Int):Void;
	static function longjmp(buf:Ptr, v:Int):Void;
	static function __mingw_longjmp(buf:Ptr, v:Int):Void;
}

@:hxmc.c @:hxmc.fast private extern class U {
	static function atexit(f:Ptr):Int;
	static function __cxa_atexit(f:Ptr, arg:Ptr, dso:Ptr):Int;
	static function _setmode(fd:Int, mode:Int):Int;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") private extern class K {
	static function GetCommandLineW():Ptr;
	static function LocalFree(p:Ptr):Ptr;
	static function ConvertThreadToFiber(p:Ptr):Ptr;
	static function CreateFiberEx(commit:I64, reserve:I64, flags:Int, entry:Ptr, arg:Ptr):Ptr;
	static function SwitchToFiber(f:Ptr):Void;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("shell32") private extern class Sh {
	static function CommandLineToArgvW(cmd:Ptr, n:Ptr):Ptr;
}
