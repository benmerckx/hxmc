// Small objects allocated in a loop (two Floats and five other fields, 64
// bytes with the header; one in eight kept a while), the time per
// allocation: what the nursery's bulk zeroing costs. Not a corpus case
// (times vary); built and run by hand:
//   bin/hxmc/hxmc -cp hxmc/test/micro -main AllocZeroBench -cp bin/hxmc/std --custom-target hxmc=bin/alloczero
//   bin/alloczero [allocations]      (default 30000000)
// In a profile (x86-64, -debug for the symbols) hxmc_zero takes about 18%:
// it is Gc.tlabRefill zeroing each TLAB as it is taken (rep stosb; the
// stub's only caller), not a zeroing per object, which no allocation does
// (the constructor's inline bump allocation stores the header and the
// fields only). It is the cost of first writing the nursery's lines, which
// the allocations take when it is not there: on an idle machine, pinned to
// one core, the minimum of 15 runs in ns per allocation is 8.0 as it is,
// 7.9 with a loop of 8-byte stores instead of rep stosb, 7.9 with the C
// library's memset, and 8.3 without zeroing at all (not correct in
// general: a constructor that leaves a field unset reads the zeros); the
// default 32 KB chunks (RT_ZCHUNK_KB) 7.8, 4 KB ones 8.3, 256 KB ones 9.6.
// Under load from other processes the runs vary by 20% and more.
class AllocZeroBench {
	static function main() {
		var args = Sys.args();
		var n:Int = args.length > 0 ? Std.parseInt(args[0]) : 30000000;
		var keep = new haxe.ds.Vector<P>(1024);
		var t0 = Sys.time();
		var sum = 0.0;
		var prev:P = null;
		for (i in 0...n) {
			var p = new P(i * 0.5, i * 0.25, i, prev);
			prev = (i & 7) == 0 ? null : p;
			if ((i & 7) == 0) keep[(i >> 3) & 1023] = p;
			sum += p.x + p.y;
		}
		var dt = Sys.time() - t0;
		Sys.println(sum + " " + Math.round(dt * 1e9 / n * 100) / 100 + " ns/alloc");
	}
}

class P {
	public var x:Float;
	public var y:Float;
	public var a:Int;
	public var b:Int;
	public var c:P;
	public var d:String;
	public var e:Bool;

	public function new(x, y, a, c) {
		this.x = x;
		this.y = y;
		this.a = a;
		this.b = a + 1;
		this.c = c;
		this.d = null;
		this.e = true;
	}
}
