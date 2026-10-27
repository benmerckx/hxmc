// hxmc.GcStats, natively and on wasm32: a known allocation shows in
// bytesAllocated (within a tolerance: the loop itself may allocate a
// little), in the nursery and as large objects straight in the old space;
// collections and pauses count up.
import haxe.ds.Vector;
import hxmc.GcStats;

class GcCounters {
	static var sink:Vector<Float>;

	static function check(what:String, got:Float, want:Float) {
		var ok = got >= want && got <= want * 1.02 + 4096;
		Sys.println(what + (ok ? ": ok" : ': $got bytes, expected $want'));
	}

	static function main() {
		// 20000 vectors of 100 Floats: 8 + 800 bytes each, in the nursery (at
		// most 4 KB: so with the smallest nursery, 16 KB, too)
		var b0 = GcStats.bytesAllocated();
		var c0 = GcStats.collections();
		for (i in 0...20000) {
			sink = new Vector<Float>(100);
			sink[0] = i;
		}
		check("small", GcStats.bytesAllocated() - b0, 20000 * 808.0);
		Sys.println("collected: " + (GcStats.collections() > c0));
		// 40 vectors of 200000 Floats: 1.6 MB each, large objects
		var b1 = GcStats.bytesAllocated();
		for (i in 0...40) {
			sink = new Vector<Float>(200000);
			sink[0] = i;
		}
		check("large", GcStats.bytesAllocated() - b1, 40 * 1600008.0);
		// a major collection: counted, its pause in the totals
		var m0 = GcStats.majorCollections();
		var t0 = GcStats.totalPause();
		hxmc.NativeGc.collect(true);
		Sys.println("major: " + (GcStats.majorCollections() == m0 + 1));
		Sys.println("pauses: " + (GcStats.lastPause() >= 0 && GcStats.totalPause() >= t0 + GcStats.lastPause() - 1e-9
			&& GcStats.maxPause() >= GcStats.lastPause() && GcStats.totalPause() < 60));
		Sys.println("minor + major: " + (GcStats.minorCollections() + GcStats.majorCollections() == GcStats.collections()));
		// nothing allocated: nothing counted
		var b2 = GcStats.bytesAllocated();
		Sys.println("still: " + (GcStats.bytesAllocated() == b2));
	}
}
