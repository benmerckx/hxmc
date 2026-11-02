// define: hxmc.wasm-memory-max=100
// A major collection with little memory to spare (issue #129). The module's
// memory is capped at 100 MB (-D hxmc.wasm-memory-max: memory.grow fails
// past it, as a browser's refusal does; natively the define does nothing).
// 48 MB of Bytes stay live while garbage is promoted and collected, then a
// major collection runs: it keeps the large object where it is rather than
// copying it, and takes the memory it may copy into before it starts. It
// used to copy the 48 MB into memory grown halfway through, which the cap
// refused: "out of memory: linear memory is 71 MB, growing it by 42 MB
// failed", from inside the collection. Then 26 MB of small objects are
// promoted and dropped: the next major collection's worst case (copying
// all of them) does not fit under the cap, so it measures what it copies
// (a trace) and reserves that. (The corpus's nurseries are small, 16 to
// 256 KB: a large one would take room under the cap.)
class GcMemoryCap {
	static var keep:haxe.io.Bytes;
	static var junk:Array<Array<Int>> = [];
	static var hold:Array<haxe.ds.Vector<Float>>;

	static function main() {
		keep = haxe.io.Bytes.alloc(48 << 20);
		for (i in 0...keep.length >> 16)
			keep.set(i << 16, i & 255);
		for (i in 0...200000) {
			junk.push([i, i, i, i, i, i, i, i]);
			if (junk.length > 1000) junk = [];
		}
		hxmc.NativeGc.collect(true);
		var ok = true;
		for (i in 0...keep.length >> 16)
			if (keep.get(i << 16) != i & 255) ok = false;
		Sys.println("survived: " + keep.length + " " + ok);
		// and again, the large object old already, with more garbage
		for (i in 0...200000) {
			junk.push([i, i]);
			if (junk.length > 1000) junk = [];
		}
		hxmc.NativeGc.collect(true);
		Sys.println("again: " + keep.get(1 << 16) + " " + junk.length);
		var sum = promoteAndDrop();
		hxmc.NativeGc.collect(true);
		Sys.println("measured: " + sum + " " + keep.get(2 << 16));
	}

	// 26 MB promoted, then dropped (in a frame of its own: none of its
	// locals is a root of the collection after it)
	static function promoteAndDrop():Float {
		hold = [];
		for (i in 0...3200) {
			var v = new haxe.ds.Vector<Float>(1000);
			v[0] = i;
			hold.push(v);
		}
		var sum = 0.0;
		for (v in hold)
			sum += v[0];
		hold = null;
		return sum;
	}
}
