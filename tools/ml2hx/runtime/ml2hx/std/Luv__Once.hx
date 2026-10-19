package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Once (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvOnceT {
	function new() {}
}

class Luv__Once {
	public static function init(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Once.LuvOnceT, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Once.init is not available in the generated compiler"); }
	public static function once(a0:ml2hx.std.Luv__Once.LuvOnceT, a1:(ml2hx.rt.Unit) -> (ml2hx.rt.Unit)):ml2hx.rt.Unit { throw new Failure("luv: Luv.Once.once is not available in the generated compiler"); }
}
