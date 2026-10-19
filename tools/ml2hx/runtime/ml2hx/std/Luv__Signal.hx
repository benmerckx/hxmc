package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Signal (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvSignalT {
	function new() {}
}

// (signal numbers: POSIX's, as Linux and macOS number them)
class Luv__Signal {
	public static function init(a1:ml2hx.rt.Unit, ?loop:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static final sigabrt:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(6);
	public static final sigfpe:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(8);
	public static final sighup:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(1);
	public static final sigill:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(4);
	public static final sigint:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(2);
	public static final sigkill:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(9);
	public static function signum(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Int63 { throw new Failure("luv: not available in the generated compiler"); }
	public static final sigsegv:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(11);
	public static final sigterm:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(15);
	public static final sigwinch:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(28);
	public static function start(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, a1:ml2hx.rt.Int63, a2:(ml2hx.rt.Unit) -> (ml2hx.rt.Unit)):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function startOneshot(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, a1:ml2hx.rt.Int63, a2:(ml2hx.rt.Unit) -> (ml2hx.rt.Unit)):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
	public static function stop(a0:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Handle.LuvctypedescriptionsDescriptionsHandleHandle<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: not available in the generated compiler"); }
}
