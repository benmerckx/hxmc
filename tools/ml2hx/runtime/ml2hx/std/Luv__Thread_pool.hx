package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv.Thread.pool: not available in the generated compiler yet
// (eval.luv); its functions raise Failure.

class Luv__Thread_pool {
	public static function queueWork(a2:(ml2hx.rt.Unit) -> (ml2hx.rt.Unit), a3:(ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant>) -> (ml2hx.rt.Unit), ?loop:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?request:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Request.LuvctypedescriptionsDescriptionsRequestRequest<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
	public static function setSize(a1:ml2hx.rt.Int63, ?ifNotAlreadySet:Bool):ml2hx.rt.Unit { throw new Failure("luv: not available in the generated compiler"); }
}
