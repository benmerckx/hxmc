package hxmc.macro;

// Native macros (docs/plans/compiler.md, "Native macros"): macro code compiled by
// hxmc and loaded into the running compiler, an hxmc executable built with
// -D hxmc.jit (Linux x86-64). The parts:
//   Guest         the compile of the macro modules, in a child process of the
//                 compiler (typed for hxmc, in macro mode): a relocatable
//                 object and the program-wide facts it needs (a "bundle")
//   Loader        links a bundle into the running compiler: its symbols
//                 (<exe>.syms), new type indices and table entries, the code
//                 mapped executable
//   Bridge        native objects to and from Eval values at the boundary
//   NativeEngine  the macro engine (macros.MacroEngine) that calls them, with
//                 Eval as the fallback and as the reference of verify mode
// This class holds what the executable's own build needs to know.
class Jit {
	// zeroed entries after rt_types and after the signature tables (DataGen)
	public static inline var SPARE_TYPES = 4096;
	public static inline var SPARE_SIGS = 1024;

	// the runtime's functions macro code may call that the compiler's own code
	// does not: a bundle calls the compiler's (Guest compiles no runtime), so
	// the executable has them (HaxeMain names them). Type.resolveClass finds a
	// bundle's classes too (the Loader counts them in), Type.createInstance
	// makes them (their entries, hxmc.ir.Lower.makers, written by the Loader)
	public static function runtime():Array<Dynamic>
		return [hxmc.Native.resolveType, hxmc.Native.createInstance];
}
