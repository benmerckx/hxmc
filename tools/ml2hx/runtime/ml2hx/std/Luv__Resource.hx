package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__Resource: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvResourceTimeval implements ml2hx.rt.Block {
	public final sec:ml2hx.std.Signed_Long.SignedLongT;
	public final usec:ml2hx.std.Signed_Long.SignedLongT;
	public function new(sec:ml2hx.std.Signed_Long.SignedLongT, usec:ml2hx.std.Signed_Long.SignedLongT) {
		this.sec = sec;
		this.usec = usec;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 2;
	public function blockField(i:Int):Dynamic return ([sec, usec] : Array<Dynamic>)[i];
}

class LuvResourceRusage implements ml2hx.rt.Block {
	public final utime:LuvResourceTimeval;
	public final stime:LuvResourceTimeval;
	public final maxrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final ixrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final idrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final isrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final minflt:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final majflt:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final nswap:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final inblock:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final oublock:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final msgsnd:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final msgrcv:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final nsignals:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final nvcsw:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final nivcsw:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public function new(utime:LuvResourceTimeval, stime:LuvResourceTimeval, maxrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ixrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, idrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, isrss:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, minflt:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, majflt:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, nswap:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, inblock:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, oublock:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, msgsnd:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, msgrcv:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, nsignals:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, nvcsw:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, nivcsw:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T) {
		this.utime = utime;
		this.stime = stime;
		this.maxrss = maxrss;
		this.ixrss = ixrss;
		this.idrss = idrss;
		this.isrss = isrss;
		this.minflt = minflt;
		this.majflt = majflt;
		this.nswap = nswap;
		this.inblock = inblock;
		this.oublock = oublock;
		this.msgsnd = msgsnd;
		this.msgrcv = msgrcv;
		this.nsignals = nsignals;
		this.nvcsw = nvcsw;
		this.nivcsw = nivcsw;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 16;
	public function blockField(i:Int):Dynamic return ([utime, stime, maxrss, ixrss, idrss, isrss, minflt, majflt, nswap, inblock, oublock, msgsnd, msgrcv, nsignals, nvcsw, nivcsw] : Array<Dynamic>)[i];
}

class Luv__Resource {
	public static function constrainedMemory(a0:ml2hx.rt.Unit):ml2hx.rt.MlOption<ml2hx.std.Unsigned_UInt64.UnsignedUInt64T> { throw new Failure("luv: Luv.Resource.constrainedMemory is not available in the generated compiler"); }
	public static function freeMemory(a0:ml2hx.rt.Unit):ml2hx.rt.MlOption<ml2hx.std.Unsigned_UInt64.UnsignedUInt64T> { throw new Failure("luv: Luv.Resource.freeMemory is not available in the generated compiler"); }
	public static function getpriority(a0:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Int63, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Resource.getpriority is not available in the generated compiler"); }
	public static function getrusage(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Luv__Resource.LuvResourceRusage, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Resource.getrusage is not available in the generated compiler"); }
	public static function loadavg(a0:ml2hx.rt.Unit):ml2hx.rt.Tuple3<Float, Float, Float> { throw new Failure("luv: Luv.Resource.loadavg is not available in the generated compiler"); }
	public static function residentSetMemory(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.std.Unsigned_Size_t.UnsignedSizetT, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Resource.residentSetMemory is not available in the generated compiler"); }
	public static function setpriority(a0:ml2hx.rt.Int63, a1:ml2hx.rt.Int63):ocaml.stdlib.StdlibModule.StdlibResult<ml2hx.rt.Unit, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Resource.setpriority is not available in the generated compiler"); }
	public static function totalMemory(a0:ml2hx.rt.Unit):ml2hx.rt.MlOption<ml2hx.std.Unsigned_UInt64.UnsignedUInt64T> { throw new Failure("luv: Luv.Resource.totalMemory is not available in the generated compiler"); }
	public static function uptime(a0:ml2hx.rt.Unit):ocaml.stdlib.StdlibModule.StdlibResult<Float, ml2hx.rt.PolyVariant> { throw new Failure("luv: Luv.Resource.uptime is not available in the generated compiler"); }
}
