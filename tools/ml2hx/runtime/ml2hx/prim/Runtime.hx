package ml2hx.prim;

import haxe.Int64;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import ml2hx.rt.*;

// OCaml's extern.c (Marshal.to_*, output_value): values written in OCaml's
// format from their OCaml shapes (as compare and hash see them: ml2hx.rt.Poly),
// sharing by physical identity of blocks: bytes too, and on hxmc strings
// (String objects, which converted code passes around as OCaml passes its
// strings; elsewhere strings are values, never shared), never floats. Ints are immediates (an int64 or nativeint, an Int64 too,
// is written as an int: their custom blocks are not told apart). Closures
// cannot be written. intern.c (input_value, Marshal.from_*) would need the
// static types of the values to rebuild them as Haxe values: not supported
// (README, gaps).
class Runtime {
	static function unsupported<T>(what:String):T throw new Failure('$what: reading marshalled data is not supported by ml2hx');

	static inline var MAGIC_SMALL = 0x8495A6BE;
	static inline var PREFIX_SMALL_BLOCK = 0x80;
	static inline var PREFIX_SMALL_INT = 0x40;
	static inline var PREFIX_SMALL_STRING = 0x20;
	static inline var CODE_INT8 = 0x0;
	static inline var CODE_INT16 = 0x1;
	static inline var CODE_INT32 = 0x2;
	static inline var CODE_INT64 = 0x3;
	static inline var CODE_SHARED8 = 0x4;
	static inline var CODE_SHARED16 = 0x5;
	static inline var CODE_SHARED32 = 0x6;
	static inline var CODE_BLOCK32 = 0x8;
	static inline var CODE_BLOCK64 = 0x13;
	static inline var CODE_STRING8 = 0x9;
	static inline var CODE_STRING32 = 0xA;
	static inline var CODE_DOUBLE_LITTLE = 0xC;
	static inline var CODE_DOUBLE_ARRAY8_LITTLE = 0xE;
	static inline var CODE_DOUBLE_ARRAY32_LITTLE = 0x7;

	// the marshalled bytes of v (header and data)
	static function externValue(v:Dynamic, flags:Dynamic):Bytes {
		var noSharing = false, closures = false;
		var l:MlList<Dynamic> = flags;
		while (true) switch l {
			case Nil: break;
			case Cons(f, t):
				switch Type.enumIndex(f) { case 0: noSharing = true; case 1: closures = true; case _: }
				l = t;
		}
		var out = new BytesBuffer();
		var objects = new haxe.ds.ObjectMap<Dynamic, Int>();
		var count = 0;
		var size32:Float = 0, size64:Float = 0;
		function u8(x:Int) out.addByte(x & 0xFF);
		function u16(x:Int) { u8(x >> 8); u8(x); }
		function u32(x:Int) { u8(x >>> 24); u8(x >>> 16); u8(x >>> 8); u8(x); }
		function u64(x:Int64) { u32(x.high); u32(x.low); }
		function record(o:Dynamic, words32:Float, words64:Float, identity:Bool) {
			size32 += words32;
			size64 += words64;
			if (noSharing) return;
			if (identity) objects.set(o, count);
			count++;
		}
		function int(n:Int64) {
			if (n >= 0 && n < 0x40) u8(PREFIX_SMALL_INT + n.low);
			else if (n >= -128 && n < 128) { u8(CODE_INT8); u8(n.low); }
			else if (n >= -32768 && n < 32768) { u8(CODE_INT16); u16(n.low); }
			else if (n >= Int64.make(-1, 0x80000000) && n < Int64.make(0, 0x80000000)) { u8(CODE_INT32); u32(n.low); }
			else { u8(CODE_INT64); u64(n); }
		}
		function shared(d:Int) {
			if (d < 0x100) { u8(CODE_SHARED8); u8(d); }
			else if (d < 0x10000) { u8(CODE_SHARED16); u16(d); }
			else { u8(CODE_SHARED32); u32(d); }
		}
		function double(f:Float) {
			var bits = haxe.io.FPHelper.doubleToI64(f);
			for (i in 0...8) u8(Int64.shr(bits, 8 * i).low);
		}
		var stack:Array<Dynamic> = [v];
		while (stack.length > 0) {
			var v:Dynamic = stack.pop();
			var k = Poly.kind(v);
			switch k {
				case Poly.K_IMM:
					int(Poly.immediate(v));
				case Poly.K_STRING | Poly.K_BYTES:
					var identity = k == Poly.K_BYTES #if (target.name == "hxmc") || true #end;
					if (identity && !noSharing && objects.exists(v)) {
						shared(count - objects.get(v));
						continue;
					}
					var s:Bytes = k == Poly.K_STRING ? ByteString.toBytes(v) : v;
					var n = s.length;
					if (n < 0x20) u8(PREFIX_SMALL_STRING + n);
					else if (n < 0x100) { u8(CODE_STRING8); u8(n); }
					else { u8(CODE_STRING32); u32(n); }
					out.addBytes(s, 0, n);
					record(v, Std.int((n + 4) / 4) + 1, Std.int((n + 8) / 8) + 1, identity);
				case Poly.K_DOUBLE:
					u8(CODE_DOUBLE_LITTLE);
					double(v);
					record(v, 3, 2, false);
				case Poly.K_FUNC:
					// (with Closures, OCaml writes code pointers, which have no counterpart here)
					if (closures) throw new Failure("output_value: closures cannot be marshalled by ml2hx");
					throw new InvalidArgument("output_value: functional value");
				case Poly.K_ABSTRACT:
					throw new InvalidArgument("output_value: abstract value (Abstract)");
				case _:
					if (!noSharing && objects.exists(v)) {
						shared(count - objects.get(v));
						continue;
					}
					var tag = Poly.tag(v, k), fs = Poly.fields(v, k);
					var n = fs.length;
					if (tag == Poly.DOUBLE_ARRAY_TAG) {
						if (n < 0x100) { u8(CODE_DOUBLE_ARRAY8_LITTLE); u8(n); }
						else { u8(CODE_DOUBLE_ARRAY32_LITTLE); u32(n); }
						for (f in fs) double(f);
						record(v, 2 * n + 1, n + 1, true);
						continue;
					}
					if (n == 0) { u8(PREFIX_SMALL_BLOCK + tag); continue; } // an atom: not recorded
					if (tag < 16 && n < 8) u8(PREFIX_SMALL_BLOCK + tag + (n << 4));
					// (a header word: size, the colour bits extern.c writes, tag)
					else if (n < (1 << 22)) { u8(CODE_BLOCK32); u32((n << 10) | 0x300 | tag); }
					else { u8(CODE_BLOCK64); u64(Int64.or(Int64.shl(Int64.ofInt(n), 10), Int64.ofInt(0x300 | tag))); }
					record(v, n + 1, n + 1, true);
					var i = n;
					while (i > 0) stack.push(fs[--i]);
			}
		}
		var data = out.getBytes();
		var b = new BytesBuffer();
		function h32(x:Int) { b.addByte((x >>> 24) & 0xFF); b.addByte((x >>> 16) & 0xFF); b.addByte((x >>> 8) & 0xFF); b.addByte(x & 0xFF); }
		h32(MAGIC_SMALL);
		h32(data.length);
		h32(count);
		h32(Std.int(size32));
		h32(Std.int(size64));
		b.addBytes(data, 0, data.length);
		return b.getBytes();
	}

	public static function camlOutputValue<T>(oc:Io.OutChannel, v:T, flags:Dynamic):Unit {
		var b = externValue(v, flags);
		return Io.camlMlOutputBytes(oc, b, Int63.zero, Int63.ofInt(b.length));
	}
	public static function camlOutputValueToBytes<T>(v:T, flags:Dynamic):Bytes return externValue(v, flags);
	public static function camlOutputValueToString<T>(v:T, flags:Dynamic):String {
		var b = externValue(v, flags);
		return ByteString.ofBytes(b, 0, b.length);
	}
	public static function camlOutputValueToBuffer<T>(buf:Bytes, ofs:Int63, len:Int63, v:T, flags:Dynamic):Int63 {
		var b = externValue(v, flags);
		if (b.length > len.toInt()) throw new Failure("Marshal.to_buffer: buffer overflow");
		buf.blit(ofs.toInt(), b, 0, b.length);
		return Int63.ofInt(b.length);
	}
	public static function camlInputValue<T>(ic:Io.InChannel):T return unsupported("input_value");
	public static function camlInputValueFromBytes<T>(b:Bytes, ofs:Int63):T return unsupported("Marshal.from_bytes");
	public static function camlMarshalDataSize(b:Bytes, ofs:Int63):Int63 {
		var o = ofs.toInt();
		var magic = (b.get(o) << 24) | (b.get(o + 1) << 16) | (b.get(o + 2) << 8) | b.get(o + 3);
		if (magic != MAGIC_SMALL) throw new Failure("Marshal.data_size: bad object");
		// (the data's size, less the 16 bytes Marshal.header_size counts of the
		// 20-byte small header)
		return Int63.ofInt(4 + ((b.get(o + 4) << 24) | (b.get(o + 5) << 16) | (b.get(o + 6) << 8) | b.get(o + 7)));
	}
}
