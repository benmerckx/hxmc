package hxmc;

// Facts about the runtime (hxmc.rt, the runtime objects) and the target's C library that the
// generated code depends on. The struct layouts are the same on every
// 64-bit target; the jmp_buf of rt_handler is not (hxmc/deps/probe.c
// prints them all).
class Abi {
	// rt_type
	public static inline var TYPE_SIZE = 112;
	public static inline var TYPE_TAG = 80;
	// rt_icache: uint32 t, int32 slot, char kind, void *fn, int32 sig
	public static inline var IC_SIZE = 32;
	public static inline var IC_SLOT = 4;
	public static inline var IC_KIND = 8;
	public static inline var IC_FN = 16;
	public static inline var IC_SIG = 24;
	// object header (Gc.hx): the type index is bits 32..47, i.e. the 16-bit
	// word at payload - 4; the kind bits 28..31 of the word at payload - 8
	public static inline var HDR_TINDEX = -4;
	public static inline var T_FIRST = 32;
	public static inline var T_ARRAY = 5;
	public static inline var T_NATIVE_ARRAY = 19;
	public static inline var T_DATE = 20; // a Date (hxmc.rt.Types)
	public static inline var T_REFBOX_P = 11;
	public static inline var T_REFBOX_I = 12;
	public static inline var T_REFBOX_F = 13;
	public static inline var K_OBJ = 0;
	public static inline var K_PARR = 1;
	public static inline var K_RAW = 2;
	public static inline var AK_PTR = 0;
	public static inline var AK_I32 = 1;
	public static inline var AK_F64 = 2;
	public static inline var AK_I64 = 3;
	public static inline var AK_BOOL = 4; // stored as AK_I32 (Types.hx); in a NativeArray, one byte per Bool

	public var name:String; // linux-x86_64, ...
	public var arm:Bool;
	public var os:String; // linux, macos, windows, wasi
	public var wasm = false; // WebAssembly (wasm.WasmGen, wasm.LinkWasm): no machine code, no C runtime object
	public var handlerSize:Int;
	public var handlerPrev:Int;
	public var handlerSp:Int;
	public var handlerAlign:Int;
	public var setjmp:String; // the C library's setjmp without the signal mask
	public var symPrefix:String; // "_" on macOS
	// how the output is linked and loaded: a static executable at a fixed
	// address, or position-independent code (PIE, shared libraries such as an
	// Android app's lib*.so). The code generators address code and data
	// pc-relatively either way (lea rip+x, adrp/add) and program-wide numbers
	// are absolute symbols, not addresses, so only the linker depends on it.
	public var reloc:RelocModel = Static;
	public var output:OutputKind = Executable;
	// how thread-local variables are reached (instruction selection)
	public var tls:TlsModel;
	// the alignment of loadable segments (Link): the largest page size the
	// target's kernels use (Android 15+ needs 16K)
	public var segAlign:Int;
	// the C library the runtime objects were built against (musl, glibc,
	// bionic, ucrt, libsystem) and, for Apple, the platform (macos, ios,
	// ios-simulator: the Mach-O build version)
	public var libc:String;
	public var platform:String;
	// the directory of the runtime objects (<rt dir>/<rtName>/rt.o): the
	// target's name, with the C library appended for a mode other than the
	// default (linux-x86_64-glibc)
	public var rtName:String;
	// a dynamically linked executable (Link): the program interpreter
	// (PT_INTERP, null: a static executable), the shared C library it binds
	// the runtime's C names from (.hxmc.imports in the runtime object: name ->
	// library, version) and whether those imports carry symbol versions
	// (.gnu.version_r). glibc: /lib64/ld-linux-x86-64.so.2 or
	// /lib/ld-linux-aarch64.so.1, versioned (glibc 2.17 as the floor, the
	// runtime objects of hxmc/deps/mkrt.sh <target>-glibc). A dynamic musl
	// mode would be /lib/ld-musl-<arch>.so.1, libc.so, unversioned.
	public var interp:Null<String> = null;
	public var versioned = false;
	// Android (android-arm64, android-x86_64): a shared library (lib<name>.so)
	// that NativeActivity loads, against Bionic: position-independent, TLS
	// through TLSDESC (a dlopen'ed library's thread-locals), 16 KB segments,
	// the imports of libc.so and the other system libraries with Bionic's
	// symbol versions (the runtime objects' table: hxmc/deps/mkrt.sh)
	public var android = false;
	// the names a shared library exports (.dynsym): its entry points (Android:
	// ANativeActivity_onCreate), the dead-code roots
	public var exports:Array<String> = [];
	// every function keeps a frame record, linked through the frame pointer
	// (rbp; x29): arm64 always (Apple's ABI requires it, and its prologue is
	// the record), x86-64 unless -D hxmc.no-frame-pointers (Options.framePointers)
	public var framePointers = false;

	function new(name, arm, os, size, prev, sp, align, setjmp, prefix) {
		this.name = name;
		this.arm = arm;
		this.os = os;
		framePointers = arm;
		handlerSize = size;
		handlerPrev = prev;
		handlerSp = sp;
		handlerAlign = align;
		this.setjmp = setjmp;
		symPrefix = prefix;
		switch os {
			case "linux":
				tls = LocalExec;
				segAlign = arm ? 0x10000 : 0x1000;
				libc = "musl";
			case "wasi":
				tls = LocalExec; // (thread-locals are globals: one thread)
				segAlign = 0x10000;
				libc = "none";
				wasm = true;
			case "macos":
				tls = MachoTlv;
				segAlign = arm ? 0x4000 : 0x1000;
				libc = "libsystem";
			case _:
				tls = WinTlsIndex;
				segAlign = 0x1000;
				libc = "ucrt";
		}
		platform = os;
		rtName = name;
	}

	// -D hxmc.libc=<libc>: the C library the program links with, where a
	// target has more than one way (Linux: musl's members linked statically,
	// the default, or the system's glibc, dynamically)
	public function setLibc(l:Null<String>) {
		if (l == null || l == libc) return;
		switch [os, l] {
			case ["linux", "glibc"] if (!android):
				libc = l;
				rtName = name + "-glibc";
				interp = arm ? "/lib/ld-linux-aarch64.so.1" : "/lib64/ld-linux-x86-64.so.2";
				versioned = true;
			case _:
				throw "hxmc: -D hxmc.libc=" + l + " is not a C library of " + name + " (" + (os == "linux" && !android ? "musl, the default, or glibc" : libc) + ")";
		}
	}

	// the output is linked against shared libraries at load time (the
	// dynamic glibc mode, Android's shared library): LinkDyn
	public function linksDynamically():Bool
		return interp != null || android || output == SharedLibrary;

	// Android: Linux's kernel and ELF with Bionic as the C library, a shared
	// library NativeActivity loads (Mem.os() is Linux's; Mem.target() 9 and 10)
	function setAndroid() {
		android = true;
		libc = "bionic";
		reloc = Pic;
		output = SharedLibrary;
		tls = Desc;
		segAlign = 0x4000;
		versioned = true;
		exports = ["ANativeActivity_onCreate"];
	}

	// iOS (ios-arm64, ios-sim-arm64): Darwin's kernel and libSystem, the
	// layouts and runtime objects of macos-arm64 (Mem.os() 1, Mem.target()
	// 3), Mach-O with the iOS or the simulator's platform in its build
	// version (LinkMachO) and an app bundle (hxmc.ios.Bundle);
	// Mem.platform() 1 or 2
	function setIos(simulator:Bool) {
		platform = simulator ? "ios-simulator" : "ios";
		rtName = "macos-arm64";
	}

	public function ios():Bool
		return platform == "ios" || platform == "ios-simulator";

	// Mem.os(): 0 Linux, 1 macOS, 2 Windows, 3 WASI
	public function osCode():Int
		return os == "linux" ? 0 : os == "macos" ? 1 : os == "windows" ? 2 : 3;

	// Mem.platform(): 0 the system's own (macOS where Mem.os() is 1), 1 iOS, 2 the iOS simulator
	public function platformCode():Int
		return platform == "ios" ? 1 : platform == "ios-simulator" ? 2 : 0;

	public static function get(target:String):Abi
		return switch target {
			case "linux-x86_64": new Abi(target, false, "linux", 216, 200, 208, 8, "_setjmp", "");
			case "linux-arm64": new Abi(target, true, "linux", 328, 312, 320, 8, "_setjmp", "");
			case "macos-arm64": new Abi(target, true, "macos", 208, 192, 200, 8, "_setjmp", "_");
			case "macos-x86_64": new Abi(target, false, "macos", 168, 152, 160, 8, "_setjmp", "_");
			case "windows-x86_64": new Abi(target, false, "windows", 272, 256, 264, 16, "_setjmp", "");
			case "windows-arm64": new Abi(target, true, "windows", 208, 192, 200, 8, "__mingw_setjmp", "");
			// (rt_handler: no jmp_buf, the try's pad checks the handler: wasm.WasmGen)
			case "wasm32-wasi": new Abi(target, false, "wasi", 24, 8, 16, 8, "_setjmp", "");
			// (Bionic's jmp_buf: 32 longs on arm64, 11 on x86-64)
			case "android-arm64" | "android-x86_64":
				var arm = target == "android-arm64";
				var a = new Abi(target, arm, "linux", arm ? 272 : 104, arm ? 256 : 88, arm ? 264 : 96, 8, "_setjmp", "");
				a.setAndroid();
				a;
			// (the device and the simulator on Apple silicon: macos-arm64's ABI)
			case "ios-arm64" | "ios-sim-arm64":
				var a = new Abi(target, true, "macos", 208, 192, 200, 8, "_setjmp", "_");
				a.setIos(target == "ios-sim-arm64");
				a;
			case _: throw "hxmc: unknown target " + target + " (linux-x86_64, linux-arm64, macos-arm64, macos-x86_64, windows-x86_64, windows-arm64, wasm32-wasi, android-arm64, android-x86_64, ios-arm64, ios-sim-arm64)";
		}
}

enum abstract RelocModel(String) to String {
	var Static = "static";
	var Pic = "pic";
}

enum abstract OutputKind(String) to String {
	var Executable = "executable";
	var SharedLibrary = "shared";
}

enum abstract TlsModel(String) to String {
	var LocalExec = "local-exec"; // static executables: thread pointer + link-time offset
	var InitialExec = "initial-exec"; // shared libraries loaded at startup: offset from the GOT
	var Desc = "desc"; // shared libraries loaded later (TLSDESC: the module's block through hxmc_tls_base, LinkDyn)
	var MachoTlv = "tlv"; // Mach-O thread-local variable descriptors
	var WinTlsIndex = "win"; // ThreadLocalStoragePointer[_tls_index] + section offset
}
