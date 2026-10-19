package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Semaphore (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvSemaphoreT {
	function new() {}
}

class Luv__Semaphore {
	public static function destroy(a0:ml2hx.std.Luv__Semaphore.LuvSemaphoreT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function init(a0:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Semaphore.LuvSemaphoreT, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function post(a0:ml2hx.std.Luv__Semaphore.LuvSemaphoreT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function trywait(a0:ml2hx.std.Luv__Semaphore.LuvSemaphoreT):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function wait(a0:ml2hx.std.Luv__Semaphore.LuvSemaphoreT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
}
