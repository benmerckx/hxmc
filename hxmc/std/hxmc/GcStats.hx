package hxmc;

// The collector's counters, the same natively and on wasm32 (docs/using.md,
// "Measuring the collector"): reading one is a few loads, and keeping them
// costs a few additions and two clock reads per collection. Bytes are what
// the program allocated since it started, its large objects included, in
// the collector's sizes (an 8-byte header and 8-byte slots); with several
// threads, other threads' current TLABs count whole. Pauses are in seconds,
// from stopping the world to resuming it. With -D hxmc.wasm-gc the engine
// collects and every counter reads 0.
class GcStats {
	// bytes allocated since the start
	public static inline function bytesAllocated():Float
		return NativeGc.bytesAllocated();

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
}
