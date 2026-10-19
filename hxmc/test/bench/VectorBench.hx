import haxe.Timer;
import sys.io.File;

typedef BenchPair = {
	var type:String;
	var work:String;
	var array:Int->Float;
	var nativeArray:Int->Float;
	var vector:Int->Float;
}

class BenchValue {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

@:build(VectorBenchMacro.build())
class VectorBench {
	static var sink = 0.0;

	static function positive(s:String):Int {
		var n = Std.parseInt(s);
		if (n == null || n <= 0) throw 'Expected a positive integer, got "$s"';
		return n;
	}

	static function median(a:Array<Float>):Float {
		var sorted = a.copy();
		sorted.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		var i = sorted.length >> 1;
		return (sorted.length & 1) != 0 ? sorted[i] : (sorted[i - 1] + sorted[i]) / 2;
	}

	static function measure(f:Int->Float, rounds:Int):{seconds:Float, checksum:Float} {
		var start = Timer.stamp();
		var checksum = f(rounds);
		var seconds = Timer.stamp() - start;
		sink += checksum;
		return {seconds: seconds, checksum: checksum};
	}

	static function fixed(x:Float):String
		return Math.isFinite(x) ? Std.string(Math.round(x * 1000) / 1000) : Std.string(x);

	static function main() {
		var args = Sys.args();
		if (args.length > 4 || args.contains("--help")) {
			Sys.println("VectorBench [length=65536] [rounds=128] [samples=7] [results.json]");
			return;
		}
		var n = args.length > 0 ? positive(args[0]) : 65536;
		var rounds = args.length > 1 ? positive(args[1]) : 128;
		var samples = args.length > 2 ? positive(args[2]) : 7;
		Sys.println('length=$n rounds=$rounds samples=$samples; median ns/element, ratio Array/Vector (>1 favors Vector)');
		Sys.println("type\twork\tArray\tNativeArray\tVector\tratio");
		var results = [];
		for (pair in setup(n)) {
			// Warm all functions and pages, then rotate their measurement order.
			var a = measure(pair.array, rounds), b = measure(pair.nativeArray, rounds), v = measure(pair.vector, rounds);
			if (a.checksum != b.checksum || a.checksum != v.checksum) throw 'Warmup checksum mismatch: ${pair.type}/${pair.work}';
			var at = [], bt = [], vt = [];
			for (sample in 0...samples) {
				for (k in 0...3) switch ((sample + k) % 3) {
					case 0: a = measure(pair.array, rounds);
					case 1: b = measure(pair.nativeArray, rounds);
					case _: v = measure(pair.vector, rounds);
				}
				if (a.checksum != b.checksum || a.checksum != v.checksum) throw 'Checksum mismatch: ${pair.type}/${pair.work}, sample $sample';
				at.push(a.seconds);
				bt.push(b.seconds);
				vt.push(v.seconds);
			}
			var am = median(at), bm = median(bt), vm = median(vt);
			var scale = 1e9 / (n * (rounds : Float));
			Sys.println('${pair.type}\t${pair.work}\t${fixed(am * scale)}\t${fixed(bm * scale)}\t${fixed(vm * scale)}\t${fixed(am / vm)}');
			results.push({type: pair.type, work: pair.work, array_seconds: at, native_seconds: bt, vector_seconds: vt,
				array_ns: am * scale, native_ns: bm * scale, vector_ns: vm * scale, ratio: am / bm, vector_ratio: am / vm, checksum: a.checksum});
		}
		Sys.println('checksum=$sink');
		if (args.length > 3) File.saveContent(args[3], haxe.Json.stringify({length: n, rounds: rounds, samples: samples, results: results}, null, "\t") + "\n");
	}
}
