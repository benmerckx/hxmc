package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__Time: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvTimeTimeval implements ml2hx.rt.Block {
	public final sec:haxe.Int64;
	public final usec:haxe.Int32;
	public function new(sec:haxe.Int64, usec:haxe.Int32) {
		this.sec = sec;
		this.usec = usec;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 2;
	public function blockField(i:Int):Dynamic return ([sec, usec] : Array<Dynamic>)[i];
}

class Luv__Time {
	public static function gettimeofday(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Time.LuvTimeTimeval, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Time.gettimeofday is not available in the generated compiler"); }
	public static function hrtime(a0:ml2hx.rt.Unit):ml2hx.std.Unsigned_UInt64.UnsignedUInt64T { throw new Failure("luv: Luv.Time.hrtime is not available in the generated compiler"); }
	public static function sleep(a0:ml2hx.rt.Int63):ml2hx.rt.Unit { throw new Failure("luv: Luv.Time.sleep is not available in the generated compiler"); }
}
