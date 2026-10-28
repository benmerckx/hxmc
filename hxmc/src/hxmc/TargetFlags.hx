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
		context.Common.macroDefinesHook = macroDefines;
		macros.eval.EvalJit.missingExternHook = evalExtern;
	}

	// The macro context's target is not the program's: hxmc.target and
	// hxmc.libc are left out of its defines, as Haxe leaves the platforms'
	// names out (Common.adaptDefinesToMacroContext). Macro code reads the
	// program's through Context.definedValue. A module the macro context types
	// sees what it sees in a native build that names no target: else
	// `#if (hxmc.target == "wasm32-wasi")` code typed there for a macro reaches
	// hxmc's runtime, which Eval cannot type (hxmc.rt.Names' Int64 calls) or
	// run. -D hxmc.macros=mir sets the compiler's own (MirMacros.setupPlatform).
	static function macroDefines(defines:core.Define.DefineContext) {
		core.Define.rawUndefine(defines, "hxmc.target");
		core.Define.rawUndefine(defines, "hxmc.libc");
	}

	// hxmc's externs in the macro context on Eval: hxmc.unsafe's (Mem, LibC,
	// Callback, ...), the runtime's, a program's @:hxmc.c classes. The code
	// generator or the runtime implements them; Eval has none of their fields.
	// A module typed for a macro may still mention them (an import, a field's
	// type, a signature), and Eval compiles every function of the modules that
	// loads, Ptr's methods calling Mem.ult among them: upstream fails there
	// ("Field index for ult not found on prototype hxmc.unsafe.Mem"). Here the
	// use compiles, and running it at macro time throws, naming the function.
	// (-D hxmc.macros=mir types the macro context for hxmc: there they are
	// what the code generator expands.)
	static function evalExtern(c:core.TType.TClass, cf:core.TType.TClassField, p:core.Globals.Pos):Null<macros.eval.EvalValue.Vfunc> {
		if (!cf.cfKind.match(Method(_)) || (c.clPath.pack[0] != "hxmc" && !core.Meta.has(Custom(":hxmc.c"), c.clMeta))) return null;
		var msg = core.Globals.sTypePath(c.clPath) + "." + cf.cfName + " is implemented by hxmc's code generator or runtime: a macro on Eval cannot use it";
		return _ -> macros.eval.EvalMisc.throwString(msg, p);
	}

	// the flags beyond the default configuration's for a target (null: the host, native)
	public static function flags(target:Null<String>):Array<String> {
		var wasm = target != null && StringTools.startsWith(target, "wasm");
		return wasm ? ["target.atomics"] : ["target.threaded", "target.atomics"];
	}
}
