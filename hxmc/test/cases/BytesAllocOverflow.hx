import haxe.io.Bytes;

// Rounding a large length to words must not make it negative and enter
// Bytes' small shared-allocation path. These lengths exceed NativeArray's
// supported byte-storage limit and must fail before allocating anything.
class BytesAllocOverflow {
	static function main() {
		for (n in [0x7FFFFFF9, 0x7FFFFFFF, -1, -0x7FFFFFFF - 1]) {
			var rejected = false;
			try {
				var b = Bytes.alloc(n);
				Sys.println('unexpected allocation: ${b.length}');
			} catch (_:Dynamic) {
				rejected = true;
			}
			if (!rejected) throw "invalid allocation accepted";
		}
		for (n in [0, 1, 7, 8, 9, 511, 512, 513]) {
			var b = Bytes.alloc(n);
			if (b.length != n) throw "wrong length";
			for (i in 0...n) if (b.get(i) != 0) throw "not zeroed";
			if (n > 0) {
				b.set(n - 1, 123);
				if (b.sub(0, n).get(n - 1) != 123) throw "wrong copy";
			}
		}
		Sys.println("ok");
	}
}
