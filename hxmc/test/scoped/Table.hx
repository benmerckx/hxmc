import hxmc.scoped.*;

// The maps' index on both faces (hxmc.rt.MapIndex): Int keys inserted (with
// updates of repeated keys), then looked up, hits and misses. Scoped: an
// IntTable on the data stacks; GC: a haxe.ds.IntMap.
//   Table scoped|gc [n]
@:hxmc.scoped class Scoped {
	public static function run(n:Int, out:Grow<Int>) {
		var t = new IntTable<Int>();
		var x = 7;
		for (i in 0...n) {
			x = (x * 1103515245 + 12345) & 0x3fffffff;
			var k = x % (n * 2);
			t.set(k, t.get(k, 0) + 1);
		}
		var hits = 0, sum = 0;
		for (r in 0...4)
			for (k in 0...n * 2) {
				var v = t.get(k, -1);
				if (v >= 0) {
					hits++;
					sum += v;
				}
			}
		out.push(t.length);
		out.push(hits);
		out.push(sum);
	}
}

class Gc {
	public static function run(n:Int, out:Array<Int>) {
		var t = new haxe.ds.IntMap<Int>();
		var x = 7;
		for (i in 0...n) {
			x = (x * 1103515245 + 12345) & 0x3fffffff;
			var k = x % (n * 2);
			var v = t.get(k);
			t.set(k, (v == null ? 0 : v) + 1);
		}
		var hits = 0, sum = 0, size = 0;
		for (_ in t.keys())
			size++;
		for (r in 0...4)
			for (k in 0...n * 2) {
				var v = t.get(k);
				if (v != null) {
					hits++;
					sum += v;
				}
			}
		out.push(size);
		out.push(hits);
		out.push(sum);
	}
}

class Table {
	static function main() {
		var args = Sys.args();
		var n = args.length > 1 ? Std.parseInt(args[1]) : 1000000;
		if (args[0] == "gc") {
			var out = [];
			Gc.run(n, out);
			for (x in out)
				Sys.println(x);
		} else {
			var out = new Grow<Int>();
			Scoped.run(n, out);
			for (x in out)
				Sys.println(x);
		}
	}
}
