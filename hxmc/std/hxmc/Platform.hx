package hxmc;

// The target a program is compiled for, as constants the compiler folds:
// `if (Platform.os() == Platform.WINDOWS)` keeps one branch, so code for
// another system is neither compiled nor linked (a comparison folds, and &&
// or || of one first: `Platform.target() >= 9 && x` is false elsewhere, x not
// even reached). Plain values, safe anywhere: GC code, kernels. hxmc.unsafe's
// Mem.os, arm, target and platform are their former names (deprecated).
extern class Platform {
	public static inline var LINUX = 0;
	public static inline var MACOS = 1;
	public static inline var WINDOWS = 2;
	public static inline var WASI = 3;

	// LINUX, MACOS, WINDOWS or WASI (WebAssembly); Android is LINUX (target() >= 9)
	static function os():Int;

	// arm64
	static function arm():Bool;

	// the target as one number: 0 linux-x86_64, 1 linux-arm64, 2
	// macos-x86_64, 3 macos-arm64, 4 windows-x86_64, 5 windows-arm64, 6
	// wasm32-wasi, 7 linux-x86_64 and 8 linux-arm64 with glibc
	// (-D hxmc.libc=glibc), 9 android-x86_64, 10 android-arm64
	static function target():Int;

	// the Apple platform where os() is MACOS: 0 macOS, 1 iOS, 2 the iOS
	// simulator, 3 Mac Catalyst (target() is macOS's)
	static function apple():Int;
}
