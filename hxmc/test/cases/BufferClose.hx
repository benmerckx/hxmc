// A Buffer's accessors lend it for the access, as a span is lent for a call
// (docs/interop.md, "Owned buffers"): close() on another thread meanwhile
// throws instead of freeing the memory under it, and once it closed, every
// access throws. A failed access lends nothing: the buffer still closes.
import haxe.io.Bytes;
import hxmc.Buffer;
import sys.thread.Lock;
import sys.thread.Thread;

class BufferClose {
	static inline var SIZE = 1 << 16;

	static function error(f:() -> Void):String
		return try {
			f();
			"none";
		} catch (e:Dynamic) Std.string(e);

	static function main() {
		var b = new Buffer(16), bytes = Bytes.alloc(8);
		Sys.println([
			error(() -> b.get(16)), error(() -> b.set(-1, 0)), error(() -> b.fill(8, 9, 0)), error(() -> b.getBytes(0, 17)),
			error(() -> b.blitFromBytes(0, bytes, 4, 5)), error(() -> b.blitToBytes(12, bytes, 0, 5)), error(() -> b.blitToBytes(0, bytes, 1, 8))
		].join(" "));
		b.blitFromBytes(8, Bytes.ofString("abcdefgh"), 0, 8);
		Sys.println(b.getBytes(8, 8).toString() + " " + b.get(9));
		b.close();
		Sys.println([
			error(() -> b.get(0)), error(() -> b.set(0, 0)), error(() -> b.fill(0, 1, 0)), error(() -> b.getBytes(0, 1)),
			error(() -> b.blitFromBytes(0, bytes, 0, 1)), error(() -> b.blitToBytes(0, bytes, 0, 1))
		].join(" "));

		// closed while another thread writes and reads it: the thread's next
		// access throws, and none writes the memory after it is freed (a buffer
		// made at once, likely in the same memory, stays zeroed)
		var rounds = 200, ended = 0, wrong = 0, clobbered = 0;
		for (round in 0...rounds) {
			var b = new Buffer(SIZE), done = new Lock(), v = 1 + round % 255, seen = "", started = new Lock(), n = 0;
			Thread.create(() -> {
				while (true)
					try {
						b.fill(0, SIZE, v);
						if (++n == 1 + round % 7) started.release();
						if (b.get(SIZE - 1) != v || b.getBytes(SIZE - 1, 1).get(0) != v) wrong++;
					} catch (e:Dynamic) {
						seen = Std.string(e);
						break;
					}
				done.release();
			});
			started.wait();
			b.set(round, v);
			while (true)
				try {
					b.close();
					break;
				} catch (e:String) {}
			var c = new Buffer(SIZE);
			done.wait();
			if (seen == "Buffer: closed") ended++;
			for (i in 0...SIZE)
				if (c.get(i) != 0) {
					clobbered++;
					break;
				}
			c.close();
		}
		Sys.println('$ended of $rounds ended by close, $wrong wrong, $clobbered clobbered');
	}
}
