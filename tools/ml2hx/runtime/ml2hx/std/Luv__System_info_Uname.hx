package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__System_info_Uname: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvSysteminfoUnameT implements ml2hx.rt.Block {
	public final sysname:String;
	public final release:String;
	public final version:String;
	public final machine:String;
	public function new(sysname:String, release:String, version:String, machine:String) {
		this.sysname = sysname;
		this.release = release;
		this.version = version;
		this.machine = machine;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 4;
	public function blockField(i:Int):Dynamic return ([sysname, release, version, machine] : Array<Dynamic>)[i];
}

class Luv__System_info_Uname {
}
