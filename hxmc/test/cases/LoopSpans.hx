// Loop versioning of span checks (hxmc/src/hxmc/LoopVersion.hx): a counted
// loop reading Bytes at its counter, up to a limit that is not their length,
// runs a copy without the checks when the limit is within the length (one
// test before the loop); past the end, the loop as it was throws at the
// first index out of range.
import haxe.io.Bytes;

class LoopSpans {
	static function sum(b:Bytes, n:Int):Int {
		var s = 0;
		for (i in 0...n)
			s += b.get(i);
		return s;
	}

	static function copy(src:Bytes, dst:Bytes, n:Int) {
		for (i in 0...n)
			dst.set(i, src.get(i) ^ 0x5A);
	}

	static function main() {
		var b = Bytes.alloc(64);
		for (i in 0...64)
			b.set(i, i * 3);
		Sys.println('sum: ${sum(b, 64)} ${sum(b, 10)} ${sum(b, 0)}');
		var d = Bytes.alloc(32);
		copy(b, d, 32);
		Sys.println('copy: ${d.get(0)} ${d.get(31)}');
		var seen = 0;
		try {
			copy(b, d, 40);
		} catch (e:Dynamic) {
			for (i in 0...32)
				if (d.get(i) == (b.get(i) ^ 0x5A)) seen++;
			Sys.println('past the end: $e after $seen');
		}
		try {
			Sys.println(sum(b, 65));
		} catch (e:Dynamic) {
			Sys.println('sum past the end: $e');
		}
	}
}
