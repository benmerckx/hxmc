import hxmc.scoped.*;

// One core, two faces (docs/plans/lowlevel.md): the maps' index
// (hxmc.rt.MapIndex) behind haxe.ds.IntMap (GC) and hxmc.scoped.IntTable
// (scoped). The same operations on both give the same answers: inserts that
// grow the table, updates, hits and misses, negative and colliding keys, a
// reference to a value kept across growth; the table's memory freed with
// its scope (a loop of tables).
@:hxmc.scoped class Pt {
	public var x:Int;
	public var y:Int;

	public function new(x, y) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.scoped class Scoped {
	public static function run(n:Int, out:Grow<Int>) {
		var t = new IntTable<Int>();
		var x = 7;
		for (i in 0...n) {
			x = (x * 1103515245 + 12345) & 0x3fffffff;
			var k = (x % (n * 2)) - n;
			t.set(k, t.get(k, 0) + i);
		}
		var hits = 0, sum = 0;
		for (k in -n...n)
			if (t.exists(k)) {
				hits++;
				sum += t.get(k, 0) * (k & 7);
			}
		out.push(t.length);
		out.push(hits);
		out.push(sum);
		// (keys 16 apart: their homes collide in a small table)
		var c = new IntTable<Pt>();
		var first = c.ref(0);
		c.set(0, new Pt(1, 2));
		first = c.ref(0);
		for (i in 1...1000)
			c.set(i * 16, new Pt(i, -i));
		first.value.y = 99;
		out.push(c.get(0, new Pt(0, 0)).y);
		out.push(c.get(16 * 999, new Pt(0, 0)).x);
		out.push(c.exists(17) ? 1 : 0);
		var ks = 0;
		for (k in c.keySlice())
			ks += k;
		out.push(ks);
		// tables in a loop: each freed with its iteration
		var total = 0;
		for (r in 0...2000) {
			var u = new IntTable<Int>();
			for (i in 0...100)
				u.set(i * r, i);
			total += u.length;
		}
		out.push(total);
	}
}

class ScopedTable {
	static function gc(n:Int, out:Array<Int>) {
		var t = new haxe.ds.IntMap<Int>();
		var x = 7;
		for (i in 0...n) {
			x = (x * 1103515245 + 12345) & 0x3fffffff;
			var k = (x % (n * 2)) - n;
			t.set(k, (t.exists(k) ? t.get(k) : 0) + i);
		}
		var hits = 0, sum = 0, size = 0;
		for (_ in t)
			size++;
		for (k in -n...n)
			if (t.exists(k)) {
				hits++;
				sum += t.get(k) * (k & 7);
			}
		out.push(size);
		out.push(hits);
		out.push(sum);
	}

	static function main() {
		var g = new Grow<Int>();
		Scoped.run(100000, g);
		var a = [];
		gc(100000, a);
		trace([for (x in g) x]);
		trace(a);
		for (i in 0...3)
			if (g[i] != a[i]) trace("differs at " + i);
		trace(hxmc.rt.DataStacks.used() < 4096 ? "small" : "large: " + hxmc.rt.DataStacks.used());
	}
}
