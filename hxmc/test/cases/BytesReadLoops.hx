import haxe.io.Bytes;

// The range tests of haxe.io.Bytes' accesses the code proves, which the
// compiler drops as it drops a span's (Opt.condProp; docs/hxmc.md,
// "Bytes"): an index below the length in a loop counting from 0 (for, while,
// a bound tested against the length first), a block at constant offsets
// after the length was tested (`if (b.length < 16) return`: every access of
// 1 to 8 bytes there, reads and writes), a table's masked index times the
// element size, a loop over words (i * 4 with i below length >> 2). And the
// ones it must keep, which still throw: a cursor from an argument, a bound
// not tested against the length, a counter that may start below 0.
// The accesses whose test is left in each function (Corpus: the loads of
// haxe.io.Error.OutsideBounds):
// bytes-checks: BytesReadLoops.sum=0 BytesReadLoops.whileSum=0 BytesReadLoops.prefix=0 BytesReadLoops.header=0 BytesReadLoops.headerWrite=0 BytesReadLoops.block=0 BytesReadLoops.table=0 BytesReadLoops.words=0 BytesReadLoops.at=1 BytesReadLoops.upTo=1 BytesReadLoops.from=1
class BytesReadLoops {
	static function sum(b:Bytes):Int {
		var s = 0;
		for (i in 0...b.length)
			s += b.get(i);
		return s;
	}

	static function whileSum(b:Bytes):Int {
		var s = 0, i = 0;
		while (i < b.length) {
			s = s * 31 + b.get(i);
			i++;
		}
		return s;
	}

	static function prefix(b:Bytes, n:Int):Int {
		if (n > b.length) return -1;
		var s = 0;
		for (i in 0...n)
			s = s * 7 + b.get(i);
		return s;
	}

	// a header of 16 bytes: a magic Int32, a version, flags, a Float, a byte
	static function header(b:Bytes):String {
		if (b.length < 16) return "short";
		return [b.getInt32(0), b.getInt32(4), b.getUInt16(8), b.getUInt16(10), b.getFloat(12) > 2 ? 1 : 0, b.get(15), b.getInt64(8).high].join(",");
	}

	static function headerWrite(b:Bytes):Void {
		if (b.length < 16) return;
		b.setInt32(0, 0x474E5089);
		b.setInt32(4, 3);
		b.setUInt16(8, 0x102);
		b.setUInt16(10, 0x304);
		b.setFloat(12, 2.5);
		b.set(15, 9);
	}

	// 8 rows of an 8x8 block of Int32s, the length tested first
	static function block(b:Bytes):Int {
		if (b.length < 256) return -1;
		var s = 0;
		for (r in 0...8)
			s += b.getInt32(r * 32) - b.getInt32(r * 32 + 28);
		return s;
	}

	static function table(b:Bytes, t:Bytes):Float {
		if (t.length < 2048) return -1;
		var s = 0.0;
		for (i in 0...b.length)
			s += t.getDouble((b.get(i) & 0xFF) * 8);
		return s;
	}

	static function words(b:Bytes):Int {
		var s = 0;
		for (i in 0...b.length >> 2)
			s += b.getInt32(i * 4);
		return s;
	}

	static function at(b:Bytes, p:Int):Int
		return b.getInt32(p);

	static function upTo(b:Bytes, n:Int):Int {
		var s = 0;
		for (i in 0...n)
			s += b.get(i);
		return s;
	}

	static function from(b:Bytes, k:Int):Int {
		var s = 0;
		for (i in k...b.length)
			s += b.get(i);
		return s;
	}

	static function main() {
		var b = Bytes.alloc(256);
		for (i in 0...256)
			b.set(i, i * 7 + 1);
		var t = Bytes.alloc(2048);
		for (i in 0...256)
			t.setDouble(i * 8, i / 4);
		var h = Bytes.alloc(16);
		headerWrite(h);
		Sys.println([sum(b), whileSum(b), prefix(b, 100), prefix(b, 300)].join(" "));
		Sys.println(header(h) + " " + header(Bytes.alloc(15)) + " " + h.toHex());
		Sys.println([block(b), block(h), Std.int(table(b, t)), words(b), at(b, 252)].join(" "));
		Sys.println([upTo(b, 256), from(b, 250)].join(" "));
		for (f in [() -> at(b, 253), () -> upTo(b, 257), () -> from(b, -1)])
			try {
				Sys.println(f());
			} catch (e:haxe.io.Error) {
				Sys.println(e);
			}
	}
}
