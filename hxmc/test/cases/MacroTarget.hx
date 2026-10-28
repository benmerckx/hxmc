// A class with a macro function is typed in the macro context too (Eval),
// every field of it. The macro context's target is not the program's: its
// defines leave hxmc.target out (hxmc.TargetFlags), so code behind
// `#if (hxmc.target == "wasm32-wasi")` is typed there as in a native build
// that names no target. With the program's hxmc.target in the macro context,
// a wasm32-wasi build typed hxmc's runtime in Eval (here a callback's
// address, and an I64 times an Int64, hxmc.rt.Names' slot hash) and failed:
// "Invalid call to static function toInt through abstract instance".
// Macro code reads the program's target with Context.definedValue.
class MacroTarget {
	static function main() {
		trace(Probe.macroSees());
		trace(Probe.mix(5));
	}
}

class Probe {
	public static macro function macroSees() {
		#if hxmc.target
		return macro "the macro context names a target";
		#else
		return macro "the macro context names no target";
		#end
	}

	public static function mix(n:Int):Int {
		#if (hxmc.target == "wasm32-wasi")
		var k:hxmc.I64 = n;
		hxmc.unsafe.Callback.addr(tick);
		return ((k * haxe.Int64.make(0, 3)) >>> 0).toInt();
		#else
		return n * 3;
		#end
	}

	#if (hxmc.target == "wasm32-wasi")
	@:hxmc.callback static function tick(n:Int):Int
		return n;
	#end
}
