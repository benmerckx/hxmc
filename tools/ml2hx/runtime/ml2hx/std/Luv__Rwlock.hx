package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Rwlock (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvRwlockT {
	function new() {}
}

class Luv__Rwlock {
	public static function destroy(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function init(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Rwlock.LuvRwlockT, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function rdlock(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function rdunlock(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function tryrdlock(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function trywrlock(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function wrlock(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function wrunlock(a0:ml2hx.std.Luv__Rwlock.LuvRwlockT):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
}
