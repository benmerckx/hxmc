package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__Network_Interface_address: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvNetworkInterfaceaddressT implements ml2hx.rt.Block {
	public final name:String;
	public final isInternal:Bool;
	public final physical:String;
	public final address:ml2hx.std.Luv__Sockaddr.LuvSockaddrT;
	public final netmask:ml2hx.std.Luv__Sockaddr.LuvSockaddrT;
	public function new(name:String, isInternal:Bool, physical:String, address:ml2hx.std.Luv__Sockaddr.LuvSockaddrT, netmask:ml2hx.std.Luv__Sockaddr.LuvSockaddrT) {
		this.name = name;
		this.isInternal = isInternal;
		this.physical = physical;
		this.address = address;
		this.netmask = netmask;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 5;
	public function blockField(i:Int):Dynamic return ([name, isInternal, physical, address, netmask] : Array<Dynamic>)[i];
}

class Luv__Network_Interface_address {
}
