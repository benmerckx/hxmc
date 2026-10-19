package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Sockaddr (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvSockaddrT {
	function new() {}
}

class Luv__Sockaddr {
	public static function ipv4(a0:String, a1:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Sockaddr.LuvSockaddrT, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Sockaddr.ipv4 is not available in the generated compiler"); }
	public static function ipv6(a0:String, a1:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Sockaddr.LuvSockaddrT, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Sockaddr.ipv6 is not available in the generated compiler"); }
	public static function port(a0:ml2hx.std.Luv__Sockaddr.LuvSockaddrT):ml2hx.rt.MlOption<ml2hx.rt.Int63> { throw new Failure("luv: Luv.Sockaddr.port is not available in the generated compiler"); }
	public static function toString(a0:ml2hx.std.Luv__Sockaddr.LuvSockaddrT):ml2hx.rt.MlOption<String> { throw new Failure("luv: Luv.Sockaddr.toString is not available in the generated compiler"); }
}
