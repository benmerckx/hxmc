// haxe.ds.StringMap against a model (parallel arrays): random sets, removals,
// lookups, copies and clears over tables of a few to hundreds of keys (the
// small tables without an index and the indexed ones, growth between them,
// removal after growth), the null key, removal while iterating, reserve;
// insertion order checked through keys, values and keyValueIterator.
class StringMapModel {
	static var seed = 12345;
	static function rnd(n:Int):Int {
		seed = (seed * 1103515245 + 12345) & 0x7fffffff;
		return (seed >> 8) % n;
	}

	static function check(m:haxe.ds.StringMap<Int>, ks:Array<String>, vs:Array<Int>, where:String) {
		if (m.size() != ks.length) throw where + " size " + m.size() + " " + ks.length;
		var i = 0;
		for (k in m.keys()) {
			if (k != ks[i]) throw where + " key order " + i + " " + k + " " + ks[i];
			i++;
		}
		if (i != ks.length) throw where + " keys count";
		i = 0;
		for (v in m) {
			if (v != vs[i]) throw where + " value order";
			i++;
		}
		i = 0;
		for (k => v in m) {
			if (k != ks[i] || v != vs[i]) throw where + " kv order";
			i++;
		}
		for (j in 0...ks.length)
			if (!m.exists(ks[j]) || m.get(ks[j]) != vs[j]) throw where + " get " + ks[j];
	}

	static function main() {
		var total = 0;
		for (round in 0...3000) {
			var m = new haxe.ds.StringMap<Int>();
			var ks:Array<String> = [], vs:Array<Int> = [];
			var range = [2, 5, 9, 17, 40, 300][round % 6];
			var ops = rnd(4 * range) + 1;
			for (o in 0...ops) {
				var r = rnd(range + 1);
				var k:String = r == range ? null : "k" + r;
				var a = rnd(10);
				if (a < 6) {
					var v = rnd(1000);
					m.set(k, v);
					var j = ks.indexOf(k);
					if (j >= 0) vs[j] = v else {
						ks.push(k);
						vs.push(v);
					}
				} else if (a < 9) {
					var j = ks.indexOf(k);
					var got = m.remove(k);
					if (got != (j >= 0)) throw "remove " + k;
					if (j >= 0) {
						ks.splice(j, 1);
						vs.splice(j, 1);
					}
				} else {
					var j = ks.indexOf(k);
					if (m.exists(k) != (j >= 0)) throw "exists " + k;
					if (m.get(k) != (j >= 0 ? vs[j] : null)) throw "get " + k;
				}
				if (rnd(50) == 0) {
					var c = m.copy();
					check(c, ks, vs, "copy");
					m = c;
				}
				if (rnd(400) == 0) {
					m.clear();
					ks = [];
					vs = [];
				}
			}
			check(m, ks, vs, "end");
			// removal while iterating
			for (k in m.keys())
				if (rnd(2) == 0) {
					m.remove(k);
					var j = ks.indexOf(k);
					ks.splice(j, 1);
					vs.splice(j, 1);
				}
			check(m, ks, vs, "iter-remove");
			var r = new haxe.ds.StringMap<Int>();
			r.reserve(rnd(40));
			for (j in 0...ks.length)
				r.set(ks[j], vs[j]);
			check(r, ks, vs, "reserve");
			total += m.size();
		}
		var e = new haxe.ds.StringMap<Int>();
		Sys.println(e.toString() + " " + e.get("a") + " " + e.remove(null) + " " + e.copy().size());
		e.set(null, 1);
		e.set("", 2);
		Sys.println(e.toString() + " " + e.get(null) + " " + e.get(""));
		e.remove(null);
		Sys.println(e.toString() + " " + e.exists(null) + " " + e.get(""));
		Sys.println("ok " + total);
	}
}
