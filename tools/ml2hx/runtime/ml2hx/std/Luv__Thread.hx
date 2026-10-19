package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Thread (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvThreadT {
	function new() {}
}

class Luv__Thread {
	public static function create(a1:(ml2hx.rt.Unit) -> (ml2hx.rt.Unit), ?stackSize:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Thread.LuvThreadT, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function join(a0:ml2hx.std.Luv__Thread.LuvThreadT):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function self(a0:ml2hx.rt.Unit):ml2hx.std.Luv__Thread.LuvThreadT { throw new Failure("luv: not available in the generated compiler"); }
	public static function equal(a:LuvThreadT, b:LuvThreadT):Bool return a == b;
}
