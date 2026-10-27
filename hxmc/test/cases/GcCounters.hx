// hxmc.GcStats, natively and on wasm32: a known allocation shows in
// bytesAllocated and the thread's threadBytesAllocated (within a tolerance:
// the loop itself may allocate a little), in the nursery and as large
// objects straight in the old space; collections, pauses and the records of
// the last collections add up; natively, another thread's allocation counts
// in the total, not in this thread's.
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
		var b0 = GcStats.bytesAllocated(), tb0 = GcStats.threadBytesAllocated();
		var c0 = GcStats.collections();
		for (i in 0...20000) {
			sink = new Vector<Float>(100);
			sink[0] = i;
		}
		check("small", GcStats.bytesAllocated() - b0, 20000 * 808.0);
		check("small, this thread", GcStats.threadBytesAllocated() - tb0, 20000 * 808.0);
		Sys.println("collected: " + (GcStats.collections() > c0));
		// 40 vectors of 200000 Floats: 1.6 MB each, large objects
		var b1 = GcStats.bytesAllocated(), tb1 = GcStats.threadBytesAllocated();
		for (i in 0...40) {
			sink = new Vector<Float>(200000);
			sink[0] = i;
		}
		check("large", GcStats.bytesAllocated() - b1, 40 * 1600008.0);
		check("large, this thread", GcStats.threadBytesAllocated() - tb1, 40 * 1600008.0);
		// a major collection: counted, its pause in the totals, its record last
		var m0 = GcStats.majorCollections();
		var t0 = GcStats.totalPause();
		var n0 = GcStats.collections();
		hxmc.NativeGc.collect(true);
		Sys.println("major: " + (GcStats.majorCollections() == m0 + 1));
		Sys.println("pauses: " + (GcStats.lastPause() >= 0 && GcStats.totalPause() >= t0 + GcStats.lastPause() - 1e-9
			&& GcStats.maxPause() >= GcStats.lastPause() && GcStats.totalPause() < 60));
		Sys.println("minor + major: " + (GcStats.minorCollections() + GcStats.majorCollections() == GcStats.collections()));
		var rs = GcStats.records();
		var last = rs[rs.length - 1];
		Sys.println("records: " + (rs.length == (GcStats.collections() < GcStats.RECORDS ? GcStats.collections() : GcStats.RECORDS))
			+ " " + (last.index == n0 && last.major && last.start <= last.stopped && last.stopped <= last.end && last.end <= GcStats.now()
				&& Math.abs(last.end - last.start - GcStats.lastPause()) < 1e-6)
			+ " " + (GcStats.records(n0).length == 1 && GcStats.records(n0 + 1).length == 0));
		var ordered = true;
		for (i in 1...rs.length)
			if (rs[i].index != rs[i - 1].index + 1 || rs[i].start < rs[i - 1].end) ordered = false;
		Sys.println("in order: " + ordered);
		#if (hxmc.target != "wasm32-wasi")
		// another thread's 2000 vectors: in the total, not in this thread's
		var b2 = GcStats.bytesAllocated(), tb2 = GcStats.threadBytesAllocated();
		var done = new sys.thread.Lock();
		var theirs = 0.0;
		sys.thread.Thread.create(() -> {
			var t = GcStats.threadBytesAllocated();
			for (i in 0...2000) {
				var v = new Vector<Float>(100);
				v[0] = i;
				if (i == 1999) sink = v;
			}
			theirs = GcStats.threadBytesAllocated() - t;
			done.release();
		});
		done.wait();
		var mine = GcStats.threadBytesAllocated() - tb2;
		Sys.println("threads: " + (theirs >= 2000 * 808.0 && theirs < 2000 * 808.0 * 1.05 && mine < 64 * 1024
			&& GcStats.bytesAllocated() - b2 >= 2000 * 808.0));
		#else
		Sys.println("threads: true");
		#end
		// nothing allocated: nothing counted
		var b3 = GcStats.bytesAllocated();
		Sys.println("still: " + (GcStats.bytesAllocated() == b3));
	}
}
