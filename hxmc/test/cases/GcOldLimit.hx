// hxmc.NativeGc.setOldLimit, natively and on wasm32: before the first major
// collection it raises the old space's first limit (hxmc.NativeGc.heapBytes:
// the limit and the nursery), unless RT_OLD_MB says otherwise; after a major
// collection it changes nothing.
class GcOldLimit {
	static var keep:Array<Array<Int>>;

	static function main() {
		var mb = 1024.0 * 1024.0;
		var fixed = Sys.getEnv("RT_OLD_MB") != null;
		hxmc.NativeGc.setOldLimit(300);
		Sys.println("raised: " + (fixed || hxmc.NativeGc.heapBytes() >= 300 * mb));
		// what is kept stays reachable through collections
		keep = [for (i in 0...20000) [i, i + 1, i + 2]];
		hxmc.NativeGc.collect(false);
		hxmc.NativeGc.collect(true);
		hxmc.NativeGc.setOldLimit(600);
		Sys.println("after a major: " + (hxmc.NativeGc.heapBytes() < 600 * mb));
		var sum = 0;
		for (a in keep) sum += a[2] - a[0];
		Sys.println("kept: " + sum);
	}
}
