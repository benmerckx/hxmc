// Maps used by threads together without a lock (docs/hxmc.md, "Maps and
// threads"): a race throws where it happens ("concurrent map writes",
// "concurrent map read and map write", "concurrent map access") instead of
// reaching outside the maps' arrays. Four threads write and read one map of
// each kind until one of them catches such a throw (a new map each round),
// while the collections run (a 64 KB nursery); no other throw, no crash.
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

class Key {
	public function new() {}
}

class MapRaces {
	// what the threads caught, of rounds of ops(t, i), each round on a map of its own (make)
	static function race(make:Void->((Int, Int) -> Void)):String {
		for (round in 0...500) {
			var op = make();
			var caught = [];
			var m = new Mutex(), done = new Lock();
			for (t in 0...4)
				Thread.create(() -> {
					var mine:Null<String> = null;
					try {
						for (i in 0...20000)
							op(t, i);
					} catch (e:String) {
						mine = e;
					} catch (e:Dynamic) {
						mine = "not a String: " + e;
					}
					m.acquire();
					if (mine != null) caught.push(mine);
					m.release();
					done.release();
				});
			for (_ in 0...4)
				done.wait();
			for (c in caught)
				if (!StringTools.startsWith(c, "concurrent map")) return "unexpected " + c;
			if (caught.length > 0) return "caught";
		}
		return "none caught";
	}

	static function main() {
		Sys.println("IntMap: " + race(() -> {
			var map = new haxe.ds.IntMap<Int>();
			(t, i) -> {
				map.set(t * 100000 + i, i);
				if (map.get(i) == -1) throw "never";
			}
		}));
		Sys.println("StringMap: " + race(() -> {
			var map = new haxe.ds.StringMap<Int>();
			(t, i) -> {
				map.set("k" + (t * 100000 + i), i);
				if (map.get("k" + i) == -1) throw "never";
			}
		}));
		var keys = [for (i in 0...20000) new Key()];
		Sys.println("ObjectMap: " + race(() -> {
			var map = new haxe.ds.ObjectMap<Key, Int>();
			(t, i) -> {
				map.set(keys[(t * 5000 + i) % keys.length], i);
				if (map.get(keys[i]) == -1) throw "never";
			}
		}));
		// (one thread: as before)
		var m = new haxe.ds.StringMap<Int>();
		for (i in 0...1000)
			m.set("k" + i, i);
		for (k in m.keys())
			if (m.get(k) % 2 == 0) m.remove(k);
		Sys.println("one thread: " + Lambda.count(m) + " left, " + m.get("k999"));
	}
}
