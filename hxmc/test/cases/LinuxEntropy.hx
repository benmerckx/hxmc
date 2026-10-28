import hxmc.unsafe.*;

// The system's random bytes in the static mode on Linux: getentropy(3) and
// getrandom(2), musl's members in rt.o (hxmc/deps/mkrt.sh), for a program
// and the C it links (a C library seeding itself from them). Bytes that
// differ from one call to the next; getentropy refuses more than 256 bytes
// (EIO), as musl's and glibc's do.
@:hxmc.c extern class Entropy {
	static function getentropy(buf:Ptr<UInt8>, len:Int64):Int;
	static function getrandom(buf:Ptr<UInt8>, len:Int64, flags:Int):Int64;
}

class LinuxEntropy {
	static function hex(p:Ptr<UInt8>, n:Int):String {
		var b = new StringBuf();
		for (i in 0...n)
			b.add(StringTools.hex(p[i], 2));
		return b.toString();
	}

	static function main() {
		Arena.scoped(a -> {
			var x:Ptr<UInt8> = a.alloc(256), y:Ptr<UInt8> = a.alloc(256);
			trace(Entropy.getentropy(x, 32), Entropy.getentropy(y, 32));
			trace(hex(x, 32) != hex(y, 32), hex(x, 32) != StringTools.lpad("", "0", 64));
			trace(Entropy.getentropy(x, 256));
			trace(Entropy.getentropy(x, 257), Linux.errno() == 5); // EIO
			var n = Entropy.getrandom(x, 64, 0);
			var m = Entropy.getrandom(y, 64, 1); // GRND_NONBLOCK
			trace(Std.string(n), Std.string(m), hex(x, 64) != hex(y, 64));
			// (with collections in between: each call leaves the arena's memory where it is)
			var ok = true, seen = new Map<String, Bool>();
			for (i in 0...2000) {
				var keep = [for (j in 0...20) "s" + j];
				if (Entropy.getentropy(x, 16) != 0) ok = false;
				var h = hex(x, 16);
				if (seen.exists(h)) ok = false;
				seen.set(h, true);
				if (keep.length != 20) ok = false;
			}
			trace(ok);
		});
	}
}
