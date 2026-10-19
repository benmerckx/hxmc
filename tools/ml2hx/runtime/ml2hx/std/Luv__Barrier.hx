package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Barrier (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvBarrierT {
	function new() {}
}

class Luv__Barrier {
	public static function destroy(a0:ml2hx.std.Luv__Barrier.LuvBarrierT):ml2hx.rt.Unit { throw new Failure("luv: Luv.Barrier.destroy is not available in the generated compiler"); }
	public static function init(a0:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Barrier.LuvBarrierT, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Barrier.init is not available in the generated compiler"); }
	public static function wait(a0:ml2hx.std.Luv__Barrier.LuvBarrierT):Bool { throw new Failure("luv: Luv.Barrier.wait is not available in the generated compiler"); }
}
