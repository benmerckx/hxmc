import haxe.io.Bytes;
import hxmc.NativeGc;
import hxmc.unsafe.*;

// hxmc.unsafe.IoBuffer (docs/interop.md, "I/O buffers"): memory outside the
// collected heap whose address stays the same through minor and major
// collections (the corpus' 64 KB nursery, NativeGc.collect), with its
// accessors, its copies to and from haxe.io.Bytes, and its view as a Bytes
// (no copy: the collector leaves the off-heap BytesData where it is while
// it moves the Bytes object holding it).
class IoBuffers {
	static var keep:Array<Dynamic> = [];

	static function churn(rounds:Int) {
		for (r in 0...rounds) {
			var a = [];
			for (i in 0...2000)
				a.push({i: i, s: "x" + i, b: Bytes.alloc(i & 63)});
			keep.push(a[r * 7 % a.length]);
			NativeGc.collect(r % 3 == 2);
		}
	}

	static function sum(b:IoBuffer):Int {
		var s = 0;
		for (i in 0...b.length)
			s = (s * 31 + b.get(i)) & 0xFFFFFF;
		return s;
	}

	static function main() {
		var small = IoBuffer.alloc(100);
		var big = IoBuffer.alloc(1 << 20);
		var addrSmall = small.ptr.toI64(), addrBig = big.ptr.toI64();
		trace(small.length, big.length, small.get(99), big.get((1 << 20) - 1));
		trace((addrSmall & 7) == 0, (addrBig & 7) == 0);
		for (i in 0...small.length)
			small.set(i, i * 3);
		for (i in 0...(big.length >> 2))
			big.setInt32(i << 2, i * 7 + 1);
		big.setDouble(8, 2.5);
		big.setI64(16, (0x1234 : hxmc.I64) << 32);
		var s0 = sum(small);

		// views: a Bytes over the buffer's bytes
		var vs = small.view(), vb = big.view();
		trace(vs.length, vb.length, vs.get(5), vb.getInt32(400), vb.getDouble(8));
		// a heap copy, a heap Bytes copied in
		var copy = small.getBytes(10, 20);
		var heap = Bytes.alloc(64);
		for (i in 0...64)
			heap.set(i, 200 - i);
		big.blitFromBytes(1000, heap, 4, 50);

		churn(30);

		// nothing moved, nothing changed
		trace(small.ptr.toI64() == addrSmall, big.ptr.toI64() == addrBig);
		trace(sum(small) == s0, small.get(33), big.getInt32(400), big.get(1000), big.get(1049));
		trace(copy.length, copy.get(0), copy.get(19));
		// the views: their Bytes objects moved, their data did not
		trace(vs.get(5), vb.getInt32(400), vb.getDouble(8), Std.string(vb.getInt64(16)));
		vs.set(7, 99);
		vb.blit(0, heap, 0, 8);
		trace(small.get(7), big.get(0), big.get(7));
		trace(vs.sub(1, 4).toHex(), vb.sub(1000, 4).toHex());
		// a buffer to a buffer, a copy of a heap Bytes
		var c = IoBuffer.ofBytes(heap, 60);
		trace(c.length, c.get(0), c.get(3));
		c.blit(0, small, 1, 4);
		trace(c.get(0), c.get(3));
		churn(10);
		trace(c.getUInt16(0), vs.toHex().length, sum(small) != s0);

		// out of range
		for (f in [() -> small.get(100), () -> small.get(-1), () -> big.getInt32((1 << 20) - 3), () -> {
			small.blitToBytes(90, heap, 0, 11);
			0;
		}, () -> {
			small.blitFromBytes(0, heap, 60, 5);
			0;
		}])
			try {
				f();
				trace("no error");
			} catch (e:haxe.io.Error) {
				trace(e);
			}
		var empty = IoBuffer.alloc(0);
		trace(empty.length, empty.view().length);
		empty.free();
		c.free();
		small.free();
		big.free();
		trace(keep.length);
	}
}
