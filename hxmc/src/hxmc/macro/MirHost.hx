package hxmc.macro;

// A Mir host: a compiler that loads code compiled for the Mir interpreter
// (Mir macros and --run: docs/hxmc.md, "Macros on the Mir interpreter"),
// which every compiler with them is on a native target (Options.mirHost,
// Mem.mirHost). The parts:
//   interp.MirMacros, interp.MirRun  compile the macro context's code, or
//                 the program, for the interpreter (interp.InterpGen): a
//                 bundle, an object without code and the program-wide facts
//                 it needs (BundleFacts)
//   Loader        links a bundle into the running compiler: its symbols
//                 (HostTable, carried by the executable), new type indices
//                 and table entries
//   interp.InterpAbi  the functions of the compiler interpreted code crosses
//                 into native code through
// This class holds what the executable's own build needs to know.
class MirHost {
	// zeroed entries after rt_types and after the signature tables (DataGen)
	// (about five times the most measured, HXMC_MACRO_STATS: upstream's unit
	// suite's macros take 339 types and no signature; a compilation server's
	// generations take theirs again, Loader.takenAgain)
	public static inline var SPARE_TYPES = 2048;
	public static inline var SPARE_SIGS = 256;

	// the runtime's functions macro code may call that the compiler's own code
	// does not: a bundle calls the compiler's (it compiles no runtime), so the
	// executable has them (HaxeMain names them). Type.resolveClass finds a
	// bundle's classes too (the Loader counts them in), Type.createInstance
	// makes them (their entries, hxmc.ir.Lower.makers, written by the Loader)
	public static function runtime():Array<Dynamic>
		return [hxmc.Native.resolveType, hxmc.Native.createInstance];
}
