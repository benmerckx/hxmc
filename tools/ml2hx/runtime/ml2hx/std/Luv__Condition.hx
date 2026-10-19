package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Condition (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvConditionT {
	function new() {}
}

class Luv__Condition {
	public static function broadcast(a0:ml2hx.std.Luv__Condition.LuvConditionT):ml2hx.rt.Unit { throw new Failure("luv: Luv.Condition.broadcast is not available in the generated compiler"); }
	public static function destroy(a0:ml2hx.std.Luv__Condition.LuvConditionT):ml2hx.rt.Unit { throw new Failure("luv: Luv.Condition.destroy is not available in the generated compiler"); }
	public static function init(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Condition.LuvConditionT, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Condition.init is not available in the generated compiler"); }
	public static function signal(a0:ml2hx.std.Luv__Condition.LuvConditionT):ml2hx.rt.Unit { throw new Failure("luv: Luv.Condition.signal is not available in the generated compiler"); }
	public static function timedwait(a0:ml2hx.std.Luv__Condition.LuvConditionT, a1:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, a2:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Condition.timedwait is not available in the generated compiler"); }
	public static function wait(a0:ml2hx.std.Luv__Condition.LuvConditionT, a1:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.Condition.wait is not available in the generated compiler"); }
}
