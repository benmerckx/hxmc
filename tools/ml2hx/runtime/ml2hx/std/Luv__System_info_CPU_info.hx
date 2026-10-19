package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv__System_info_CPU_info: records (made by luv's functions, not available in the
// generated compiler yet).

class LuvSysteminfoCPUinfoTimes implements ml2hx.rt.Block {
	public final user:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final nice:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final sys:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final idle:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final irq:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public function new(user:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, nice:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, sys:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, idle:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, irq:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T) {
		this.user = user;
		this.nice = nice;
		this.sys = sys;
		this.idle = idle;
		this.irq = irq;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 5;
	public function blockField(i:Int):Dynamic return ([user, nice, sys, idle, irq] : Array<Dynamic>)[i];
}

class LuvSysteminfoCPUinfoT implements ml2hx.rt.Block {
	public final model:String;
	public final speed:ml2hx.rt.Int63;
	public final times:LuvSysteminfoCPUinfoTimes;
	public function new(model:String, speed:ml2hx.rt.Int63, times:LuvSysteminfoCPUinfoTimes) {
		this.model = model;
		this.speed = speed;
		this.times = times;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 3;
	public function blockField(i:Int):Dynamic return ([model, speed, times] : Array<Dynamic>)[i];
}

class Luv__System_info_CPU_info {
}
