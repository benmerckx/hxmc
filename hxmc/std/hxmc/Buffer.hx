package hxmc;

import haxe.io.Bytes;
import haxe.io.Error;
import haxe.atomic.AtomicInt;
import hxmc.unsafe.IoBuffer;

// Memory outside the GC heap that safe code owns (docs/interop.md, "Owned
// buffers"): a runtime-sized block of zeroed bytes, lent to kernels and C
// calls as spans for one call (Span.ofBuffer), freed by close(). Lending
// and closing are atomic: a call that holds a span of it keeps it open, so
// close() while a span is lent (a callback of that call, another thread)
// throws instead of freeing the memory under it. Nothing frees it but
// close(): scoped() closes it on every path.
//
//   var buf = new Buffer(4096);
//   var n = Posix.read(fd, Span.ofBuffer(buf));
//   var bytes = buf.getBytes(0, n);
//   buf.close();
@:hxmc.unsafe(gc) @:allow(hxmc.SpanSupport)
final class Buffer {
	var io:IoBuffer;
	var size:Int;
	// the spans lent (-1: closed)
	var lends = new AtomicInt(0);

	public var length(get, never):Int;

	public function new(length:Int) {
		io = IoBuffer.alloc(length);
		size = length;
	}

	// a buffer, f(it), closed after f whatever happens (no closure: inlined)
	public static inline function scoped<T>(length:Int, f:Buffer->T):T {
		var b = new Buffer(length);
		try {
			var r = f(b);
			b.close();
			return r;
		} catch (e:Dynamic) {
			b.close();
			throw e;
		}
	}

	inline function get_length():Int
		return lends.load() < 0 ? 0 : size;

	public var closed(get, never):Bool;

	inline function get_closed():Bool
		return lends.load() < 0;

	// frees the memory; a closed buffer is empty. Throws while a span is lent
	public function close():Void {
		if (lends.load() < 0) return;
		if (lends.compareExchange(0, -1) != 0) throw "Buffer.close: a span of it is lent to a running call";
		io.free();
		size = 0;
	}

	function open():IoBuffer {
		if (lends.load() < 0) throw "Buffer: closed";
		return io;
	}

	public function get(pos:Int):Int
		return open().get(pos);

	public function set(pos:Int, v:Int):Void
		open().set(pos, v);

	public function fill(pos:Int, len:Int, v:Int):Void
		open().fill(pos, len, v);

	public function getBytes(pos:Int, len:Int):Bytes
		return open().getBytes(pos, len);

	public function blitFromBytes(pos:Int, src:Bytes, srcpos:Int, len:Int):Void
		open().blitFromBytes(pos, src, srcpos, len);

	public function blitToBytes(pos:Int, dst:Bytes, dstpos:Int, len:Int):Void
		open().blitToBytes(pos, dst, dstpos, len);

	// (Span.ofBuffer, FnLower.spanCall: the range checked as the arguments
	// are evaluated, the span lent once they are, released after the call)
	function range(pos:Int, len:Int):Int {
		if (lends.load() < 0) throw "Buffer: closed";
		if (len < 0) len = size - pos;
		if (pos < 0 || len < 0 || pos > size - len) throw Error.OutsideBounds;
		return len;
	}

	// n, the span lent; -1 if it closed since its range was checked (another thread)
	@:hxmc.unsafe function take(n:Int):Int {
		while (true) {
			var k = lends.load();
			if (k < 0) return -1;
			if (lends.compareExchange(k, k + 1) == k) return n;
		}
		return -1;
	}

	@:hxmc.unsafe function release():Void
		lends.sub(1);

	@:hxmc.unsafe function addr(pos:Int):hxmc.I64
		return io.ptr.add(pos).toI64();
}
