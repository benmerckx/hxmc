package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Mutex (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvMutexT {
	function new() {}
}

class Luv__Mutex {
	public static function destroy(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.Mutex.destroy is not available in the generated compiler"); }
	public static function init(a1:ml2hx.rt.Unit, ?recursive:Bool):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Mutex.init is not available in the generated compiler"); }
	public static function lock(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.Mutex.lock is not available in the generated compiler"); }
	public static function trylock(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Mutex.trylock is not available in the generated compiler"); }
	public static function unlock(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.Mutex.unlock is not available in the generated compiler"); }
}
