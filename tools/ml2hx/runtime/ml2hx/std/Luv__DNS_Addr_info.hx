package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__DNS_Addr_info: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvDNSAddrinfoT implements ml2hx.rt.Block {
	public final family:ml2hx.rt.PolyVariant;
	public final socktype:ml2hx.rt.PolyVariant;
	public final protocol:ml2hx.rt.Int63;
	public final addr:ml2hx.std.Luv__Sockaddr.LuvSockaddrT;
	public final canonname:ml2hx.rt.MlOption<String>;
	public function new(family:ml2hx.rt.PolyVariant, socktype:ml2hx.rt.PolyVariant, protocol:ml2hx.rt.Int63, addr:ml2hx.std.Luv__Sockaddr.LuvSockaddrT, canonname:ml2hx.rt.MlOption<String>) {
		this.family = family;
		this.socktype = socktype;
		this.protocol = protocol;
		this.addr = addr;
		this.canonname = canonname;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 5;
	public function blockField(i:Int):Dynamic return ([family, socktype, protocol, addr, canonname] : Array<Dynamic>)[i];
}

class Luv__DNS_Addr_info {
}
