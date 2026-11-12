import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.Handle;
import hxmc.I64;
import hxmc.unsafe.*;

// Typed C bindings (docs/interop.md, "Typed bindings"): spans passed as an
// address and a length (or an address alone, @:hxmc.len), out-structs as a
// span of one, handles only C makes (one with an invalid value, cleared by
// the function closing it), callbacks by name, a span result; @:hxmc.safe:
// the declaration vouches, so safe kernels call them (reject/CBinding* the
// rules); make native-check NATIVE=header compiles them against CBindings.h.
@:hxmc.struct @:hxmc.cname("struct cb_qr") @:publicFields class QR {
	var q:Int32;
	var r:Int32;
}

@:hxmc.handle(0) abstract Obj(Ptr) {}

@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("CBindings.h") extern class Lib {
	static function cb_sum(p:ReadOnlySpan<UInt8>):I64;
	@:hxmc.len(p, n) static function cb_fill(p:Span<UInt8>, v:Int, n:USize):Void;
	@:hxmc.len(out, 1) static function cb_divmod(a:Int, b:Int, out:Span<QR>):Int;
	static function cb_open(v:Int):Obj;
	static function cb_value(o:Obj):Int;
	@:hxmc.close(o) static function cb_close(o:Obj):Int;
	static function cb_apply(f:Int->Int, v:Int):Int;
	@:hxmc.len(1) static function cb_counter():Span<Int>;
}

// (not @:hxmc.fast: in a safe region, so no Bytes; an IoBuffer's span)
@:hxmc.c @:hxmc.safe @:hxmc.header("CBindings.h") extern class Slow {
	static function cb_slow_sum(p:ReadOnlySpan<UInt8>):I64;
}

class Holder {
	public var obj:Obj;

	public function new(v:Int)
		obj = Lib.cb_open(v);

	public function close():Int
		return Lib.cb_close(obj);
}

class CBindings {
	@:hxmc.callback @:hxmc.unsafe static function square(v:Int):Int
		return v * v;

	@:hxmc.kernel static function kernelSum():I64 {
		var s:Span<UInt8> = Span.stack(10);
		Lib.cb_fill(s, 1, 10);
		return Lib.cb_sum(s);
	}

	@:hxmc.kernel static function divide(a:Int, b:Int):Int {
		var qr:Span<QR> = Span.stack(1);
		if (Lib.cb_divmod(a, b, qr) != 0) return -1;
		return qr[0].q * 1000 + qr[0].r;
	}

	@:hxmc.kernel static function objects():Int {
		var o = Lib.cb_open(2);
		if (!Handle.valid(o)) return -1;
		var v = Lib.cb_value(o);
		Lib.cb_close(o);
		// (o holds the invalid value now: no use after close)
		return v + (Handle.valid(o) ? 0 : 1);
	}

	@:hxmc.kernel static function bump(n:Int):Int {
		var c = Lib.cb_counter();
		for (_ in 0...n)
			c[0] += 1;
		return c[0];
	}

	@:hxmc.kernel static function applied(v:Int):Int
		return Lib.cb_apply(square, v);

	static function main() {
		var b = Bytes.ofString("hello, world");
		trace(Lib.cb_sum(ReadOnlySpan.ofBytes(b)), Lib.cb_sum(ReadOnlySpan.ofBytes(b, 7, 5)));
		Lib.cb_fill(Span.ofBytes(b), 65, 3);
		trace(b.toString());
		trace(kernelSum(), divide(47, 5), divide(1, 0));
		trace(objects());
		var h = new Holder(3);
		trace(Lib.cb_value(h.obj), h.close(), Handle.valid(h.obj));
		trace(bump(3), bump(2));
		trace(applied(4), Lib.cb_apply(square, 2));
		var io = IoBuffer.alloc(16);
		io.fill(0, 16, 2);
		trace(Slow.cb_slow_sum(ReadOnlySpan.ofIoBuffer(io)), Slow.cb_slow_sum(ReadOnlySpan.ofIoBuffer(io, 4, 4)));
		io.free();
	}
}
