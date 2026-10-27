// Arrays grown by push to megabytes, larger than the old space's first
// limit: each growth allocates the new storage in the old space, which may
// collect and move the old storage. Boxes.arrGrow checked that the storage
// had not changed meanwhile through its raw address, so a moving collection
// looked like another thread's change and the growth retried; on wasm32,
// whose old space is sized to what is live, each retry collected again,
// recursing until the wasm stack ran out (or forever with a deeper stack).
class LargeArrays {
	static function main() {
		var n = 2000000;
		var a:Array<Float> = [];
		for (i in 0...n)
			a.push(i * 0.5);
		var s = 0.0;
		for (x in a)
			s += x;
		Sys.println("floats " + a.length + " " + s);
		var b:Array<Int> = [];
		for (i in 0...n)
			b.push(i & 1023);
		var t = 0;
		for (x in b)
			t += x;
		Sys.println("ints " + b.length + " " + t);
		// references: the storage is scanned, and its elements move with it
		var c:Array<String> = [];
		for (i in 0...300000)
			c.push(i % 1000 == 0 ? "s" + i : null);
		var k = 0;
		for (x in c)
			if (x != null) k += x.length;
		Sys.println("refs " + c.length + " " + k + " " + c[299000]);
		// grown in one go past its capacity (Arr.grow)
		var d:Array<Float> = [];
		d[n - 1] = 1.5;
		d[2 * n - 1] = 2.5;
		Sys.println("set " + d.length + " " + d[n - 1] + " " + d[2 * n - 1] + " " + d[n]);
	}
}
