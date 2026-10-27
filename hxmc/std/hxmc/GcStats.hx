package hxmc;

// The collector's counters, the same natively and on wasm32 (docs/using.md,
// "Measuring the collector"): reading one is a few loads, and keeping them
// costs a few additions, three clock reads and a record's four stores per
// collection. Bytes are what the program allocated since it started, its
// large objects included, in the collector's sizes (an 8-byte header and
// 8-byte slots); with several threads, other threads' current TLABs count
// whole in bytesAllocated. Pauses are in seconds, from the collecting
// thread's request to resuming the world (stopping it included).
class GcStats {
	// the collections records() keeps
	public static inline var RECORDS = NativeGc.RECORDS;

	// bytes allocated since the start, by every thread
	public static inline function bytesAllocated():Float
		return NativeGc.bytesAllocated();

	// bytes the calling thread allocated since it started
	public static inline function threadBytesAllocated():Float
		return NativeGc.threadBytesAllocated();

	// collections, minor and major
	public static inline function collections():Int
		return NativeGc.counts(0);

	public static inline function minorCollections():Int
		return NativeGc.counts(1);

	public static inline function majorCollections():Int
		return NativeGc.counts(2);

	// the last collection's pause, every pause added up, and the longest, in seconds
	public static inline function lastPause():Float
		return NativeGc.pause(0);

	public static inline function totalPause():Float
		return NativeGc.pause(1);

	public static inline function maxPause():Float
		return NativeGc.pause(2);

	// now on the clock of records' times (monotonic seconds)
	public static inline function now():Float
		return NativeGc.clock();

	// the collections since `since` (a GcRecord's index + 1; 0: the first),
	// of the last RECORDS, oldest first
	public static function records(since:Int = 0):Array<GcRecord> {
		var n = NativeGc.recordCount();
		var from = n - RECORDS;
		if (from < since) from = since;
		if (from < 0) from = 0;
		return [
			for (k in from...n)
				{
					index: k,
					start: NativeGc.recordField(k, 0),
					stopped: NativeGc.recordField(k, 1),
					end: NativeGc.recordField(k, 2),
					major: NativeGc.recordField(k, 3) != 0
				}
		];
	}
}

// a collection: its index (counted from 0 since the start), when the
// collecting thread asked for it, when every thread had stopped, when the
// world resumed (seconds on GcStats.now's clock), and whether it was major
typedef GcRecord = {
	final index:Int;
	final start:Float;
	final stopped:Float;
	final end:Float;
	final major:Bool;
}
