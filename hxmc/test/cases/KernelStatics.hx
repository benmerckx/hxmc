import hxmc.I64;

// Kernels write statics of plain values (docs/interop.md, "Kernels"): Int,
// Float, Bool, I64, the C scalars, enum abstracts and @:hxmc.struct values
// of them, a @:hxmc.threadLocal static too (reject/KernelStaticGc and
// KernelStaticPtr: not of a GC or raw type). The optimizer knows which
// kernels write statics (Facts.writesStatics): a static read between two
// calls of one that does is read again, never reused from before them; a
// kernel that writes none (pure) leaves it as it was. No inlining here:
// the kernels stay calls.
// define: hxmc.inline=0,0,0
@:hxmc.struct @:publicFields class Pair {
	var a:Int;
	var b:Float;

	inline function new(a:Int, b:Float) {
		this.a = a;
		this.b = b;
	}
}

enum abstract Mode(Int) {
	var Idle;
	var Busy;
}

class KernelStatics {
	static var count = 0;
	static var total:I64 = 0;
	static var mode = Idle;
	static var flag = false;
	static var last = new Pair(0, 0);
	@:hxmc.threadLocal static var mine:Int;

	@:hxmc.kernel static function bump(k:Int):Int {
		count += k;
		total = total + (k : I64) * (count : I64);
		mode = count % 2 == 0 ? Idle : Busy;
		flag = !flag;
		mine++;
		var s = 0;
		for (i in 0...k)
			s += (i * count) & 7;
		last = new Pair(count, s * 0.5);
		return count;
	}

	@:hxmc.kernel static function pure(k:Int):Int {
		var s = 0;
		for (i in 0...k)
			s += (i * k) & 7;
		return s;
	}

	static function main() {
		var seen = 0, reads = 0;
		for (i in 0...10) {
			var before = count;
			seen += bump(1);
			reads += count - before;
			seen += bump(2);
			reads += count - before;
			reads += pure(i) * 0 + count;
		}
		trace(count, seen, reads, Std.string(total), mode == Busy, flag, mine, last.a, last.b);
	}
}
