import haxe.Timer;
import haxe.io.Bytes;

// haxe.io.Bytes' reads in decoder-like loops (docs/hxmc.md, "Bytes"): a byte
// sum over the whole buffer (`for (i in 0...b.length) b.get(i)`: the loop
// proves the index), a little-endian 32-bit word sum (getInt32 at 4 * i, i
// below length >> 2), a record parse (a tag byte, a UInt16, an Int32 and a
// Float at a cursor that walks the buffer: a check each), and a table of
// 256 Doubles indexed by a byte (`t.getDouble((x & 0xFF) * 8)` after the
// table's length is tested). The median of 7 runs, in nanoseconds per
// access. Not a corpus case (times vary); built and run by hand:
//   bin/hxmc/hxmc bin/bytesread -cp hxmc/test/micro -main BytesReadBench -cp bin/hxmc/std --custom-target hxmc [-D hxmc.target=wasm32-wasi]
//   bin/bytesread [bytes]                (default 64 KB)
class BytesReadBench {
	static function sumBytes(b:Bytes):Int {
		var s = 0;
		for (i in 0...b.length)
			s += b.get(i);
		return s;
	}

	static function sumWords(b:Bytes):Int {
		var s = 0;
		for (i in 0...b.length >> 2)
			s += b.getInt32(i * 4);
		return s;
	}

	// (records of 11 bytes: tag, UInt16, Int32, Float)
	static function records(b:Bytes):Float {
		var p = 0, s = 0.0, n = b.length - 11;
		while (p <= n) {
			var tag = b.get(p);
			var a = b.getUInt16(p + 1);
			var c = b.getInt32(p + 3);
			var f = b.getFloat(p + 7);
			s += tag + a + c + (f > 0 ? 1 : 0);
			p += 11;
		}
		return s;
	}

	static function table(b:Bytes, t:Bytes):Float {
		if (t.length < 2048) return 0;
		var s = 0.0;
		for (i in 0...b.length)
			s += t.getDouble((b.get(i) & 0xFF) * 8);
		return s;
	}

	static function time(name:String, units:Float, f:() -> Float) {
		var r = [], v = 0.0;
		for (k in 0...7) {
			var t0 = Timer.stamp();
			v = f();
			r.push((Timer.stamp() - t0) * 1e9 / units);
		}
		r.sort(Reflect.compare);
		Sys.println('$name ${Math.round(r[3] * 1000) / 1000} $v');
	}

	static function main() {
		var args = Sys.args();
		var n = args.length > 0 ? Std.parseInt(args[0]) : 65536;
		var passes = Std.int(256 * 1024 * 1024 / n);
		var b = Bytes.alloc(n);
		var x = 0x9E3779B9;
		for (i in 0...n) {
			x ^= x << 13;
			x ^= x >>> 17;
			x ^= x << 5;
			b.set(i, x);
		}
		var t = Bytes.alloc(2048);
		for (i in 0...256)
			t.setDouble(i * 8, i * 0.5);
		time("get", n * passes, () -> {
			var s = 0;
			for (p in 0...passes) s += sumBytes(b);
			return s;
		});
		time("getInt32", (n >> 2) * passes, () -> {
			var s = 0;
			for (p in 0...passes) s += sumWords(b);
			return s;
		});
		time("record", Std.int(n / 11) * 4 * passes, () -> {
			var s = 0.0;
			for (p in 0...passes) s += records(b);
			return s;
		});
		time("table", n * passes, () -> {
			var s = 0.0;
			for (p in 0...passes) s += table(b, t);
			return s;
		});
	}
}
