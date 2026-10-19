// haxe.ds.IntMap, StringMap and ObjectMap (hxmc/std/haxe/ds): empty tables
// have no arrays until their first set (every read of an empty table, a set
// into one of two empty tables, clear and removal of the last entry), grown
// tables allocate theirs for the entries that fit (growth past several
// capacities, removals then growth, insertion order kept), Float, Bool and
// null values, many tables across collections, and tables made by a static
// initializer (which may run before the maps' own).
// (a class whose static initializer makes a table only through the Map
// abstract: nothing orders its initialization after the maps')
private class EarlyAbstract {
	public static var m = new Map<String, Int>();
}

class MapTables {
	static var earlyEmpty = new haxe.ds.StringMap<Int>();
	static var early = ["a" => 1];

	static function show<K, V>(m:haxe.Constraints.IMap<K, V>):String {
		var parts = [];
		for (k in m.keys())
			parts.push(Std.string(k) + "=" + Std.string(m.get(k)));
		return "[" + parts.join(",") + "]";
	}

	static function main() {
		Sys.println(show(earlyEmpty) + " " + show(early) + " " + earlyEmpty.exists("a") + " " + [for (k in EarlyAbstract.m.keys()) k].length);
		earlyEmpty.set("b", 2);
		Sys.println(show(earlyEmpty) + " " + show(early));
		// empty tables: every read, and two tables that both start empty
		var a = new haxe.ds.IntMap<String>(), b = new haxe.ds.IntMap<String>();
		Sys.println(a.get(1) + " " + a.exists(1) + " " + a.remove(1) + " " + a.size() + " " + a.toString() + " " + a.keys().hasNext() + " "
			+ a.iterator().hasNext() + " " + a.copy().size());
		a.set(1, "one");
		Sys.println(show(a) + " " + show(b) + " " + b.exists(1));
		b.set(2, "two");
		Sys.println(show(a) + " " + show(b));
		// clear, then use again; removal of the last entry, then use again
		a.clear();
		Sys.println(show(a) + " " + a.size() + " " + a.get(1));
		a.set(3, "three");
		Sys.println(show(a));
		Sys.println(b.remove(2) + " " + show(b) + " " + b.size());
		b.set(4, "four");
		Sys.println(show(b));

		// growth past several capacities, removals, then more growth
		var m = new haxe.ds.IntMap<Int>();
		for (i in 0...1000)
			m.set(i * 7 - 300, i);
		var s = 0;
		for (v in m)
			s += v;
		Sys.println(m.size() + " " + s + " " + m.get(-300) + " " + m.get(6693) + " " + m.get(5));
		for (i in 0...1000)
			if (i % 3 != 0) m.remove(i * 7 - 300);
		Sys.println(m.size() + " " + [for (k in m.keys()) k].slice(0, 5).join(","));
		for (i in 0...50)
			m.set(100000 + i, i);
		var ks = [for (k in m.keys()) k];
		Sys.println(m.size() + " " + ks.slice(ks.length - 3).join(",") + " " + m.get(100049));

		// StringMap and ObjectMap the same way
		var sm = new haxe.ds.StringMap<Float>(), sm2 = new haxe.ds.StringMap<Float>();
		Sys.println(sm.get("x") + " " + sm.exists("") + " " + sm.toString() + " " + show(sm.copy()));
		for (i in 0...100)
			sm.set("k" + i, i / 4);
		sm2.set("only", 1.5);
		Sys.println(sm.size() + " " + sm.get("k99") + " " + sm.get("k3") + " " + show(sm2));
		sm.clear();
		sm.set("again", -0.5);
		Sys.println(show(sm));
		var keys = [for (i in 0...40) {id: i}];
		var om = new haxe.ds.ObjectMap<{id:Int}, Bool>(), om2 = new haxe.ds.ObjectMap<{id:Int}, Bool>();
		Sys.println(om.get(keys[0]) + " " + om.exists(keys[0]) + " " + om.remove(keys[0]) + " " + om.toString());
		for (k in keys)
			om.set(k, k.id % 2 == 0);
		om2.set(keys[5], true);
		var evens = 0;
		for (k in om.keys())
			if (om.get(k)) evens++;
		Sys.println(evens + " " + om.exists(keys[39]) + " " + om2.exists(keys[4]) + " " + om2.get(keys[5]));
		var nm = new haxe.ds.StringMap<Null<Int>>();
		nm.set("n", null);
		Sys.println(nm.exists("n") + " " + nm.get("n") + " " + nm.size());

		// many tables across collections, most empty, some kept
		var kept = [];
		for (i in 0...200000) {
			var t = new haxe.ds.IntMap<String>();
			if (i % 1000 == 0) {
				t.set(i, "v" + i);
				kept.push(t);
			}
		}
		var total = 0;
		for (t in kept)
			for (k in t.keys())
				total += k + t.get(k).length;
		Sys.println(kept.length + " " + total);
	}
}
