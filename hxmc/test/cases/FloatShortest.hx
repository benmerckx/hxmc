// Std.string of doubles as JavaScript's Number.prototype.toString writes
// them (FloatText.format: Schubfach's digits): random doubles of every
// exponent, integers, subnormals, powers of two and their neighbours, each
// line its bits and its text; the golden file is node's String(x) of each.
// 100000 more read back as themselves.
import hxmc.I64;
import hxmc.unsafe.Mem;

class FloatShortest {
	static var seed:I64 = 88172645;

	static function next():I64 {
		seed = seed ^ (seed << 13);
		seed = seed ^ (seed >>> 7);
		seed = seed ^ (seed << 17);
		return seed;
	}

	static function hex(v:I64):String {
		var b = new StringBuf();
		for (i in 0...16)
			b.add("0123456789abcdef".charAt(((v >>> (60 - 4 * i)) & 15).toInt()));
		return b.toString();
	}

	static function random(i:Int):I64 {
		var b = next();
		var mantissa = b & ((((1 : I64) << 52)) - 1);
		return switch (i & 7) {
			case 0 | 1: mantissa | (((1023 + (i >> 3) % 60 - 30) : I64) << 52); // near 1
			case 2: mantissa; // subnormal
			case 3: Mem.f64Bits(((b >>> 20).toInt() & 0x3fffffff) * 1.0); // integer
			case _: b & ((((1 : I64) << 63)) - 1);
		}
	}

	static function main() {
		var shown:Array<I64> = [];
		for (i in 0...2000)
			shown.push(random(i));
		for (t in 1...40)
			shown.push(t);
		var e = 1;
		while (e < 0x7FF) {
			var p:I64 = (e : I64) << 52;
			shown.push(p);
			shown.push(p + 1);
			shown.push(p - 1);
			e += 23;
		}
		shown.push((0x7FE : I64) << 52 | (((1 : I64) << 52) - 1));
		for (v in [0.1, 0.2, 0.3, 0.1 + 0.2, 1e21, 1e-7, 1e-6, 123456789012345680000.0, 9007199254740993.0, 4.35, -2.5e-8])
			shown.push(Mem.f64Bits(v));
		for (b in shown) {
			var v = Mem.bitsF64(b);
			if (v != v) continue;
			Sys.println(hex(b) + " " + Std.string(v));
		}
		var bad = 0;
		for (i in 0...100000) {
			var v = Mem.bitsF64(random(i));
			if (v != v || v - v != 0) continue;
			if (Std.parseFloat(Std.string(v)) != v) bad++;
		}
		Sys.println("read back: " + bad + " differ");
	}
}
