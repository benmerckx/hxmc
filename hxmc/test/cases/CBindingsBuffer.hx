import hxmc.Buffer;
import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.*;

// An owned buffer (docs/interop.md, "Owned buffers"): memory outside the GC
// heap, lent as spans to C calls and kernels for one call, freed by close(),
// which a running call that holds it refuses (a callback of the call here).
@:hxmc.c @:hxmc.safe @:hxmc.header("CBindingsBuffer.h") extern class B {
	@:hxmc.fast static function bb_fill(p:Span<UInt8>, v:Int):Void;
	@:hxmc.fast static function bb_sum(p:ReadOnlySpan<UInt8>):I64;
	static function bb_with(p:Span<UInt8>, f:Void->Void):Int;
}

class CBindingsBuffer {
	static var buf:Buffer;

	@:hxmc.callback static function during() {
		try {
			buf.close();
			trace("closed during the call");
		} catch (e:Dynamic) {
			trace(e);
		}
	}

	@:hxmc.kernel static function count(s:ReadOnlySpan<UInt8>, v:Int):Int {
		var n = 0;
		for (i in 0...s.length)
			if (s[i] == v) n++;
		return n;
	}

	static function main() {
		buf = new Buffer(100);
		trace(buf.length, B.bb_sum(ReadOnlySpan.ofBuffer(buf)));
		B.bb_fill(Span.ofBuffer(buf, 10, 20), 1);
		trace(B.bb_sum(ReadOnlySpan.ofBuffer(buf)), buf.get(10), buf.get(29), buf.get(30));
		trace(count(ReadOnlySpan.ofBuffer(buf), 0), count(ReadOnlySpan.ofBuffer(buf, 0, 10), 0));
		trace(B.bb_with(Span.ofBuffer(buf), during), buf.get(0));
		trace(try B.bb_sum(ReadOnlySpan.ofBuffer(buf, 90, 20)) catch (e:haxe.io.Error) Std.string(e));
		buf.close();
		trace(buf.closed, buf.length);
		trace(try B.bb_sum(ReadOnlySpan.ofBuffer(buf)) catch (e:Dynamic) Std.string(e));
		trace(try buf.get(0) catch (e:Dynamic) Std.string(e));
		buf.close();
		var total = 0.0;
		for (i in 0...10000)
			total += Buffer.scoped(64, b -> {
				B.bb_fill(Span.ofBuffer(b), i & 0xFF);
				(cast B.bb_sum(ReadOnlySpan.ofBuffer(b)) : Float);
			});
		trace(total);
	}
}
