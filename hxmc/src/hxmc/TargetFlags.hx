package hxmc;

// The hxmc target's feature flags. A custom target gets the default platform
// configuration (haxe/src/context/Common.hx, defaultConfig), from which
// Common.initPlatform defines target.static and static, target.sys and sys,
// target.utf16 and utf16, target.unicode: all true of hxmc (static types, the
// sys API, UTF-16 strings, full Unicode). Two more hold for hxmc, defined here
// once the target is initialized and before the init macros and typing:
// - target.threaded on the native targets: OS threads in parallel
//   (hxmc.rt.Threads), as on hl, cpp and jvm (sys.thread, haxe.EventLoop's
//   per-thread loops); not on wasm32-wasi, whose threads run one at a time
//   (hxmc.NativeThread);
// - target.atomics on every target: haxe.atomic (hxmc/std/haxe/atomic).
// They are flags only: nothing else in the compiler reads those fields of the
// configuration. (Upstream's way, `hxmc.Init.init()` calling
// Compiler.setPlatformConfiguration, would also turn off skipping
// non-nullable optional arguments, which its decoding always does; and an
// init macro cannot define a target.* flag.) docs/hxmc.md, "Target flags".
class TargetFlags {
	public static function install() {
		var prev = compiler.Compiler.beforeTypingHook;
		// (the flags first: the hooks before, the module cache's, read the defines)
		compiler.Compiler.beforeTypingHook = function(com, actx) {
			if (com.platform.match(CustomTarget("hxmc")))
				for (f in flags(core.Define.rawDefined(com.defines, "hxmc.target") ? core.Define.rawDefinedValue(com.defines, "hxmc.target") : null))
					context.Common.rawDefine(com, f);
			if (prev != null) prev(com, actx);
		}
	}

	// the flags beyond the default configuration's for a target (null: the host, native)
	public static function flags(target:Null<String>):Array<String> {
		var wasm = target != null && StringTools.startsWith(target, "wasm");
		return wasm ? ["target.atomics"] : ["target.threaded", "target.atomics"];
	}
}
