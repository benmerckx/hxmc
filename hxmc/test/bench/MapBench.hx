// Identity-keyed and string-keyed maps: haxe.ds.ObjectMap get/set/exists on
// objects (hits and misses, keys looked up in a shuffled order), and
// StringMap's for comparison (make bench-maps; MAP_BENCH_ARGS: keys, rounds).
// Prints the fastest and the median nanoseconds per operation of each workload.
class MapBench {
	static var sink = 0;

	static function main() {
		var args = Sys.args();
		var n = args.length > 0 ? Std.parseInt(args[0]) : 1000000;
		var rounds = args.length > 1 ? Std.parseInt(args[1]) : 5;
		var sizes = n > 10000 ? [10000, n] : [n];
		for (size in sizes) {
			var keys = [for (i in 0...size) new Key(i)];
			var others = [for (i in 0...size) new Key(-i)];
			var order = [for (i in 0...size) i];
			var seed = 12345;
			for (i in 0...size) { // (Fisher-Yates, a fixed sequence)
				seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
				var j = seed % (i + 1);
				var t = order[i];
				order[i] = order[j];
				order[j] = t;
			}
			var shuffled = [for (i in order) keys[i]];
			var othersShuffled = [for (i in order) others[i]];
			var reps = Std.int(Math.max(1, 1000000 / size));
			var results = new Map<String, Array<Float>>();
			function time(name:String, ops:Int, f:Void->Void) {
				var t = haxe.Timer.stamp();
				f();
				var dt = haxe.Timer.stamp() - t;
				var a = results.get(name);
				if (a == null) results.set(name, a = []);
				a.push(dt * 1e9 / ops);
			}
			for (r in 0...rounds) {
				var m = new haxe.ds.ObjectMap<Key, Key>();
				time("obj set (insert)", size * reps, () -> for (_ in 0...reps) {
					m = new haxe.ds.ObjectMap<Key, Key>();
					for (k in keys) m.set(k, k);
				});
				time("obj get (hit)", size * reps, () -> for (_ in 0...reps) {
					var s = 0;
					for (k in shuffled) s += m.get(k).id;
					sink += s;
				});
				time("obj exists (hit)", size * reps, () -> for (_ in 0...reps) {
					var s = 0;
					for (k in shuffled) if (m.exists(k)) s++;
					sink += s;
				});
				time("obj get (miss)", size * reps, () -> for (_ in 0...reps) {
					var s = 0;
					for (k in othersShuffled) if (m.get(k) == null) s++;
					sink += s;
				});
				time("obj set (update)", size * reps, () -> for (_ in 0...reps) {
					for (k in shuffled) m.set(k, k);
				});
				var mi = new haxe.ds.ObjectMap<Key, Int>();
				for (k in keys) mi.set(k, k.id);
				time("obj<Int> get (hit)", size * reps, () -> for (_ in 0...reps) {
					var s = 0;
					for (k in shuffled) s += mi.get(k);
					sink += s;
				});
				time("obj remove+set", size * reps, () -> for (_ in 0...reps) {
					for (k in shuffled) {
						m.remove(k);
						m.set(k, k);
					}
				});
				var names = [for (k in keys) "key" + k.id];
				var sh = [for (i in order) names[i]];
				var sm = new haxe.ds.StringMap<Int>();
				time("str set (insert)", size, () -> for (s in names) sm.set(s, 1));
				time("str get (hit)", size * reps, () -> for (_ in 0...reps) {
					var t = 0;
					for (s in sh) t += sm.get(s);
					sink += t;
				});
			}
			Sys.println('$size keys (${reps}x), ns/op over $rounds rounds, min / median:');
			var names = [for (k in results.keys()) k];
			names.sort(Reflect.compare);
			for (name in names) {
				var a = results.get(name);
				a.sort(Reflect.compare);
				Sys.println('  ${StringTools.rpad(name, " ", 20)} ${Math.round(a[0] * 10) / 10} / ${Math.round(a[a.length >> 1] * 10) / 10}');
			}
		}
		if (sink == 42) Sys.println("");
	}
}

class Key {
	public var id:Int;

	public function new(id)
		this.id = id;
}
