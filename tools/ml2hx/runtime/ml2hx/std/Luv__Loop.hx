package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Loop (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvLoopT {
	function new() {}
}

class Luv__Loop {
	public static function alive(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):Bool { throw new Failure("luv: Luv.Loop.alive is not available in the generated compiler"); }
	public static function close(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Loop.close is not available in the generated compiler"); }
	public static function defaultValue(a0:ml2hx.rt.Unit):ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Loop.defaultValue is not available in the generated compiler"); }
	public static function init(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Loop.init is not available in the generated compiler"); }
	public static function libraryShutdown(a0:ml2hx.rt.Unit):ml2hx.rt.Unit { throw new Failure("luv: Luv.Loop.libraryShutdown is not available in the generated compiler"); }
	public static function now(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.std.Unsigned_UInt64.UnsignedUInt64T { throw new Failure("luv: Luv.Loop.now is not available in the generated compiler"); }
	public static function run(a2:ml2hx.rt.Unit, ?loop:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?mode:ml2hx.rt.PolyVariant):Bool { throw new Failure("luv: Luv.Loop.run is not available in the generated compiler"); }
	public static function stop(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.Loop.stop is not available in the generated compiler"); }
	public static function updateTime(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.Loop.updateTime is not available in the generated compiler"); }
}
