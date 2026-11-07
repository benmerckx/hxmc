import hxmc.Buf;

// The compiler's little-endian buffer: emit words, read them back, patch
// unaligned words, and verify the result. Run under GNU time; compile with
// the version of hxmc/src/hxmc/Buf.hx being measured on the class path.
class BufBench {
	static function main() {
		var words = 1 << 22;
		var b = new Buf(4 * words);
		var sum = 0;
		for (round in 0...8) {
			b.len = 0;
			for (i in 0...words) b.u32(i ^ round);
			for (i in 0...words) sum += b.get32(4 * i);
			for (i in 0...words - 1) b.set32(4 * i + 1, i ^ round);
			for (i in 0...words - 1)
				if (b.get32(4 * i + 1) != (i ^ round)) throw "wrong patch";
		}
		Sys.println(sum);
	}
}
