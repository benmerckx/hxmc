// haxe.ds.ObjectMap across collections (docs/hxmc.md, "Identity maps": keys
// hashed by address, the index brought up to date after the collector moves
// them): keys added young and looked up after minor and major collections,
// many keys with removals and additions in between (a model array says what
// each map must hold), several maps sharing keys, a map read only long after
// its keys moved, keys that never move (static data: class values, enum
// constructors without arguments) and keys allocated straight in the old
// space (large arrays), identity rather than equality (two equal strings,
// boxed Ints), copy, clear, iteration (in no defined order: compared as a
// set), and threads reading one map at once after a collection (one thread
// on WebAssembly). Run with a small nursery (the corpus' 64 KB) and
// RT_VERIFY=1, collections come every few hundred allocations.
import haxe.ds.ObjectMap;
import hxmc.NativeGc;

private class Key {
	public var id:Int;
	public var pad:Array<Int>; // (some keys are larger)

	public function new(id:Int, big:Bool) {
		this.id = id;
		if (big) pad = [for (i in 0...id % 7) i];
	}
}

private enum Color {
	Red;
	Green;
	Blue;
	Mixed(r:Int);
}

class ObjectMapGc {
	static var failures = 0;

	static function check(what:String, ok:Bool) {
		if (!ok) {
			failures++;
			if (failures <= 20) Sys.println("FAIL " + what);
		}
	}

	// garbage, so that collections come during the loops
	static var junk:Array<Array<Int>> = [];

	static function churn(n:Int) {
		for (i in 0...n)
			junk[i & 15] = [i, i + 1, i + 2];
	}

	// what m holds against the model: vals[id] (-1 absent) for keys[id]
	static function verify(what:String, m:ObjectMap<Key, Int>, keys:Array<Key>, vals:Array<Int>) {
		var n = 0, sum = 0;
		for (id in 0...keys.length) {
			var v = vals[id];
			var k = keys[id];
			if (v < 0) {
				check(what + ": absent " + id, !m.exists(k) && m.get(k) == null);
			} else {
				n++;
				sum += v;
				check(what + ": get " + id, m.get(k) == v);
				check(what + ": exists " + id, m.exists(k));
			}
		}
		check(what + ": size", m.size() == n);
		// iteration: each live key once, with its value
		var seen = 0, isum = 0;
		var once = new ObjectMap<Key, Bool>();
		for (k in m.keys()) {
			check(what + ": key twice", !once.exists(k));
			once.set(k, true);
			check(what + ": iterated key", vals[k.id] >= 0);
			seen++;
		}
		for (v in m)
			isum += v;
		check(what + ": iteration " + seen + "/" + n, seen == n && isum == sum);
		return n;
	}

	static function main() {
		var rnd = 12345;
		inline function next(n:Int):Int {
			rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
			return (rnd >> 8) % n;
		}

		// keys added while young, collections in between, then removals and additions
		var keys:Array<Key> = [];
		var vals:Array<Int> = [];
		var m = new ObjectMap<Key, Int>();
		var m2 = new ObjectMap<Key, Int>(); // (every third key, the same objects)
		for (i in 0...6000) {
			var k = new Key(i, i % 5 == 0);
			keys.push(k);
			vals.push(i * 3);
			m.set(k, i * 3);
			if (i % 3 == 0) m2.set(k, i);
			churn(i % 4);
			if (i % 997 == 0) NativeGc.collect(false);
			if (i % 2500 == 0) NativeGc.collect(true);
			// a key added just now, and one added long ago
			check("young " + i, m.get(k) == i * 3);
			var old = keys[next(i + 1)];
			check("older " + old.id, m.get(old) == vals[old.id]);
		}
		Sys.println("added: " + verify("added", m, keys, vals));
		for (round in 0...6) {
			for (j in 0...1500) {
				var id = next(keys.length);
				switch next(4) {
					case 0:
						check("remove " + id, m.remove(keys[id]) == (vals[id] >= 0));
						vals[id] = -1;
					case 1:
						// a new key object for the slot: young
						var k = new Key(id, next(2) == 0);
						m.remove(keys[id]);
						keys[id] = k;
						vals[id] = round * 100000 + id;
						m.set(k, vals[id]);
					case 2:
						vals[id] = round * 1000 + j;
						m.set(keys[id], vals[id]);
					case _:
						check("get " + id, m.get(keys[id]) == (vals[id] < 0 ? null : vals[id]));
				}
				churn(3);
			}
			if (round % 2 == 1) NativeGc.collect(round == 3);
			Sys.println("round " + round + ": " + verify("round " + round, m, keys, vals));
		}
		// the second map, untouched since: its keys moved meanwhile
		var hits = 0;
		for (k in m2.keys())
			if (m2.get(k) == k.id) hits++;
		Sys.println("second map: " + m2.size() + " keys, " + hits + " found");

		// a map whose entries are mostly young when the collection comes (indexed again whole)
		var fresh = new ObjectMap<Key, Int>();
		var fk = [for (i in 0...300) new Key(i, false)];
		for (k in fk)
			fresh.set(k, k.id + 1);
		NativeGc.collect(false);
		var ok = true;
		for (k in fk)
			if (fresh.get(k) != k.id + 1) ok = false;
		for (i in 0...150)
			fresh.remove(fk[i * 2]);
		NativeGc.collect(true);
		for (i in 0...300)
			if (fresh.exists(fk[i]) != (i % 2 == 1)) ok = false;
		Sys.println("fresh: " + ok + " " + fresh.size());

		// keys that never move, and keys allocated in the old space
		var mixed = new ObjectMap<Dynamic, String>();
		var big = [for (i in 0...3) [for (j in 0...200000) j]]; // (large: straight to the old space)
		var s1 = "ab" + Std.string(next(1)), s2 = "ab" + Std.string(next(1)); // equal, not the same
		var b1:Dynamic = 1000000 + next(1), b2:Dynamic = 1000000 + next(1);
		var colors:Array<Dynamic> = [Red, Green, Blue, Mixed(1), Mixed(1)];
		mixed.set(ObjectMapGc, "class");
		mixed.set(Key, "class Key");
		for (i in 0...big.length)
			mixed.set(big[i], "big " + i);
		mixed.set(s1, "s1");
		mixed.set(b1, "b1");
		for (i in 0...colors.length)
			mixed.set(colors[i], "color " + i);
		for (pass in 0...3) {
			churn(5000);
			NativeGc.collect(pass == 1);
			var r = [
				mixed.get(ObjectMapGc), mixed.get(Key), mixed.get(big[0]), mixed.get(big[2]), mixed.get(s1), mixed.get(s2), mixed.get(b1), mixed.get(b2),
				mixed.get(Red), mixed.get(Blue), mixed.get(colors[3]), mixed.get(colors[4]), mixed.get(Mixed(1))
			];
			Sys.println("mixed " + pass + ": " + r.join(","));
		}

		// copy and clear across collections
		var c = m.copy();
		NativeGc.collect(false);
		Sys.println("copy: " + verify("copy", c, keys, vals));
		c.clear();
		check("cleared", c.size() == 0 && !c.exists(keys[0]));
		c.set(keys[0], 7);
		NativeGc.collect(true);
		Sys.println("after clear: " + c.get(keys[0]) + " " + c.size());

		// many small maps, keys young and old mixed, with collections
		var maps = [for (i in 0...200) new ObjectMap<Key, Int>()];
		for (round in 0...20) {
			for (i in 0...200) {
				var k = next(2) == 0 ? keys[next(keys.length)] : new Key(next(1000), false);
				maps[i].set(k, round);
				check("small " + i, maps[i].get(k) == round);
			}
			churn(200);
		}
		var total = 0;
		for (mm in maps) {
			for (k in mm.keys())
				check("small key", mm.exists(k));
			total += mm.size();
		}
		Sys.println("small maps: " + (total > 3000));

		threads(m, keys, vals);
		Sys.println(failures == 0 ? "ok" : failures + " failures");
	}

	// threads reading one map at once, collections meanwhile (the first to
	// find the map out of date brings it up to date)
	static function threads(m:ObjectMap<Key, Int>, keys:Array<Key>, vals:Array<Int>) {
		#if (hxmc.target == "wasm32-wasi" || hxmc.wasm_gc)
		var bad = 0;
		for (t in 0...4)
			for (r in 0...20) {
				for (id in 0...keys.length)
					if (m.get(keys[id]) != (vals[id] < 0 ? null : vals[id])) bad++;
				churn(500);
			}
		Sys.println("threads: " + (bad == 0));
		#else
		var done = new sys.thread.Deque<Int>();
		for (t in 0...4)
			sys.thread.Thread.create(() -> {
				var bad = 0;
				for (r in 0...20) {
					for (id in 0...keys.length)
						if (m.get(keys[id]) != (vals[id] < 0 ? null : vals[id])) bad++;
					var g = [for (i in 0...500) [i]]; // (collections)
					if (g.length == 0) bad++;
				}
				done.add(bad);
			});
		var bad = 0;
		for (t in 0...4)
			bad += done.pop(true);
		Sys.println("threads: " + (bad == 0));
		#end
	}
}
