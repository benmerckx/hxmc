import haxe.io.Bytes;
import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// A view of descriptors as typed bindings (docs/interop.md, "Typed
// bindings"): read, write and pipe over spans, @:hxmc.fast and
// @:hxmc.safe, so checked kernels call them, and GC code lends a Bytes
// where BytesPtr stood. Linux and macOS.
@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("unistd.h") extern class Fds {
	static function read(fd:Int, buf:Span<UInt8>):I64;
	static function write(fd:Int, buf:ReadOnlySpan<UInt8>):I64;
	@:hxmc.len(fds, 2) static function pipe(fds:Span<Int>):Int;
	static function close(fd:Int):Int;
}

class CBindingsFds {
	// a pipe, its two descriptors packed: read << 16 | write
	@:hxmc.kernel static function open():Int {
		var fds:Span<Int> = Span.stack(2);
		return Fds.pipe(fds) != 0 ? -1 : (fds[0] << 16) | fds[1];
	}

	@:hxmc.kernel static function greet(fd:Int):Int {
		var b:Span<UInt8> = Span.stack(5);
		for (i in 0...5)
			b[i] = "a".code + i;
		return Fds.write(fd, b).toInt();
	}

	@:hxmc.kernel static function sum(fd:Int, scratch:Span<UInt8>):Int {
		var n = Fds.read(fd, scratch).toInt(), s = 0;
		for (i in 0...n)
			s += scratch[i];
		return s;
	}

	static function main() {
		var p = open();
		var r = p >> 16, w = p & 0xFFFF;
		trace(greet(w), Fds.write(w, ReadOnlySpan.ofBytes(Bytes.ofString("abc"))));
		var b = Bytes.alloc(8);
		trace(Fds.read(r, Span.ofBytes(b, 0, 5)), b.sub(0, 5).toString());
		trace(sum(r, Span.ofBytes(Bytes.alloc(16))));
		Fds.close(r);
		Fds.close(w);
	}
}
