package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv.DNS: not available in the generated compiler yet
// (eval.luv); its functions raise Failure.

class Luv__DNS {
	public static function getaddrinfo(a8:ml2hx.rt.Unit, a9:(ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.MlList<ml2hx.std.Luv__DNS_Addr_info.LuvDNSAddrinfoT>, ml2hx.rt.PolyVariant>) -> (ml2hx.rt.Unit), ?loop:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?request:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Request.LuvctypedescriptionsDescriptionsRequestRequest<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?family:ml2hx.rt.PolyVariant, ?socktype:ml2hx.rt.PolyVariant, ?protocol:ml2hx.rt.Int63, ?flags:ml2hx.rt.MlList<ml2hx.rt.PolyVariant>, ?node:String, ?service:String):ml2hx.rt.Unit { throw new Failure("luv: Luv.DNS.getaddrinfo is not available in the generated compiler"); }
	public static function getnameinfo(a3:ml2hx.std.Luv__Sockaddr.LuvSockaddrT, a4:(ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Tuple2<String, String>, ml2hx.rt.PolyVariant>) -> (ml2hx.rt.Unit), ?loop:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.rt.PolyVariant, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?request:ml2hx.std.Ctypes_static.CtypesstaticPointer<ml2hx.std.Ctypes_static.CtypesstaticStructured<ml2hx.std.Luv_c_type_descriptions_Descriptions_Request.LuvctypedescriptionsDescriptionsRequestRequest<ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ml2hx.rt.PolyVariant>, ?flags:ml2hx.rt.MlList<ml2hx.rt.PolyVariant>):ml2hx.rt.Unit { throw new Failure("luv: Luv.DNS.getnameinfo is not available in the generated compiler"); }
}
