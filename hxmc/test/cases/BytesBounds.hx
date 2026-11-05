import haxe.io.Bytes;
import haxe.io.Error;

// haxe.io.Bytes' reads test their range as its writes do (docs/hxmc.md,
// "Bytes"): out of range each accessor throws haxe.io.Error.OutsideBounds,
// the value writes throw (as Eval's multi-byte reads, HashLink's writes).
// Reads out of range were not tested: get(len) returned the byte after the
// data, getInt32(len - 3) bytes of the next object, and a range near 2^31
// (sub, getString, BytesBuffer.addBytes: pos + len wrapped) read far
// outside the heap. Each accessor at the last position inside, straddling
// the end, one past it, before 0 and near 2^31 (pos + size wraps), on
// lengths 0 to 16; the setters the same; the ranges of sub, getString,
// blit, fill, BytesInput, BytesBuffer, an output's writeBytes and the typed
// arrays; getInt64 and setInt64 test their 8 bytes at once. (Eval's get
// out of range is null, and its other reads throw OutsideBounds;
// HashLink's reads give 0.)
class BytesBounds {
	static inline var MAX = 0x7FFFFFFF;
	static inline var MIN = -0x7FFFFFFF - 1;

	// "ok <v>", or what was thrown
	static function run(f:() -> Dynamic):String {
		return try "ok " + f() catch (e:Error) e == Error.OutsideBounds ? "OB" : "Error " + e catch (e:Dynamic) "other " + e;
	}

	static function line(name:String, f:() -> Dynamic)
		Sys.println(name + ": " + run(f));

	static function filled(n:Int):Bytes {
		var b = Bytes.alloc(n);
		for (i in 0...n)
			b.set(i, i * 17 + 3);
		return b;
	}

	static function main() {
		// each accessor of size n at the positions that matter for a length
		var readers:Array<{name:String, size:Int, f:(Bytes, Int) -> Dynamic}> = [
			{name: "get", size: 1, f: (b, p) -> b.get(p)},
			{name: "getUInt16", size: 2, f: (b, p) -> b.getUInt16(p)},
			{name: "getInt32", size: 4, f: (b, p) -> b.getInt32(p)},
			{name: "getInt64", size: 8, f: (b, p) -> Std.string(b.getInt64(p))},
			{name: "getFloat", size: 4, f: (b, p) -> haxe.io.FPHelper.floatToI32(b.getFloat(p))},
			{name: "getDouble", size: 8, f: (b, p) -> Std.string(haxe.io.FPHelper.doubleToI64(b.getDouble(p)))},
		];
		var writers:Array<{name:String, size:Int, f:(Bytes, Int) -> Void}> = [
			{name: "set", size: 1, f: (b, p) -> b.set(p, 1)},
			{name: "setUInt16", size: 2, f: (b, p) -> b.setUInt16(p, 1)},
			{name: "setInt32", size: 4, f: (b, p) -> b.setInt32(p, 1)},
			{name: "setInt64", size: 8, f: (b, p) -> b.setInt64(p, haxe.Int64.make(1, 2))},
			{name: "setFloat", size: 4, f: (b, p) -> b.setFloat(p, 1)},
			{name: "setDouble", size: 8, f: (b, p) -> b.setDouble(p, 1)},
		];
		function positions(len:Int, size:Int):Array<Int>
			return [len - size, len - size + 1, len - 1, len, len + 1, -1, -size, MIN, MAX, MAX - size + 2];
		for (len in [0, 1, 3, 4, 7, 8, 16]) {
			Sys.println('-- length $len');
			for (r in readers) {
				var b = filled(len);
				Sys.println(r.name + " " + [for (p in positions(len, r.size)) '$p:' + run(() -> r.f(b, p))].join(" "));
			}
			for (w in writers) {
				var b = filled(len);
				Sys.println(w.name + " " + [for (p in positions(len, w.size)) '$p:' + run(() -> {
					w.f(b, p);
					"";
				})].join(" ") + " " + b.toHex());
			}
		}

		// the value a read throws is a write's: haxe.io.Error.OutsideBounds,
		// its name as its message
		var b = filled(8);
		var r:Dynamic = null, w:Dynamic = null;
		try b.getInt32(5) catch (e:Dynamic) r = e;
		try b.setInt32(5, 0) catch (e:Dynamic) w = e;
		Sys.println('read ${Std.string(r)} write ${Std.string(w)} same ${r == w} isError ${Std.isOfType(r, Error)} index ${Type.enumIndex(r)}');
		try b.get(8) catch (e:haxe.Exception) Sys.println('as haxe.Exception: ${e.message} ${Std.isOfType(e, haxe.ValueException)}');
		try b.set(8, 0) catch (e:haxe.Exception) Sys.println('as haxe.Exception: ${e.message} ${Std.isOfType(e, haxe.ValueException)}');

		// ranges: sub, getString, blit, fill, compare
		Sys.println("-- ranges");
		for (len in [0, 8]) {
			var b = filled(len);
			var big = filled(64);
			for (pr in [[0, len], [len, 0], [0, len + 1], [1, len], [-1, 1], [0, -1], [len, 1], [MAX, 1], [MAX - 15, 32], [1, MAX], [MIN, 4]]) {
				var p = pr[0], n = pr[1];
				line('len $len sub($p, $n)', () -> b.sub(p, n).toHex());
				line('len $len getString($p, $n)', () -> b.getString(p, n).length);
				line('len $len blit from($p, $n)', () -> {
					big.blit(0, b, p, n);
					big.sub(0, 4).toHex();
				});
				line('len $len blit into($p, $n)', () -> {
					b.blit(p, big, 0, n);
					b.toHex();
				});
				line('len $len fill($p, $n)', () -> {
					b.fill(p, n, 0x55);
					b.toHex();
				});
			}
			line('len $len compare', () -> b.compare(filled(len)) + " " + b.compare(big));
		}
		var e = Bytes.alloc(0);
		line("empty toString", () -> "[" + e.toString() + "] [" + e.toHex() + "]");
		line("empty sub(0, 0)", () -> e.sub(0, 0).length);
		line("empty getString(0, 0)", () -> e.getString(0, 0).length);

		// streams over Bytes
		Sys.println("-- streams");
		var src = filled(16);
		line("BytesInput(16, 4) reads", () -> {
			var i = new haxe.io.BytesInput(src, 12, 4);
			var s = [for (k in 0...4) i.readByte()];
			try i.readByte() catch (e:haxe.io.Eof) s.push(-1);
			s.join(",");
		});
		line("BytesInput(MAX - 15, 32)", () -> new haxe.io.BytesInput(src, MAX - 15, 32).readByte());
		line("BytesInput(17)", () -> new haxe.io.BytesInput(src, 17).readByte());
		line("BytesInput.readBytes", () -> {
			var i = new haxe.io.BytesInput(src);
			var out = Bytes.alloc(4);
			i.readBytes(out, 0, 4) + " " + out.toHex() + " " + run(() -> i.readBytes(out, MAX - 1, 4));
		});
		line("BytesInput.position", () -> {
			var i = new haxe.io.BytesInput(src);
			i.position = 100;
			var r = run(() -> i.readByte());
			i.position = -5;
			i.position + " " + r + " " + i.readByte();
		});
		line("BytesBuffer.addBytes(MAX - 15, 32)", () -> {
			var bb = new haxe.io.BytesBuffer();
			bb.addBytes(src, MAX - 15, 32);
			bb.length;
		});
		line("BytesBuffer.addBytes(8, 9)", () -> {
			var bb = new haxe.io.BytesBuffer();
			bb.addBytes(src, 8, 9);
			bb.length;
		});
		line("BytesOutput", () -> {
			var o = new haxe.io.BytesOutput();
			o.writeBytes(src, 14, 2);
			o.getBytes().toHex() + " " + run(() -> o.writeBytes(src, MAX - 15, 32));
		});
		line("stdout writeBytes(MAX - 15, 32)", () -> Sys.stdout().writeBytes(src, MAX - 15, 32));

		// typed arrays over Bytes (their bytes' accessors)
		Sys.println("-- typed arrays");
		// (upstream's: an index is tested against the bytes, not the view; a
		// write out of the view writes nothing)
		var u = haxe.io.UInt8Array.fromBytes(src, 4, 8);
		line("UInt8Array[7]", () -> u[7]);
		line("UInt8Array[8] (past the view, inside the bytes)", () -> u[8]);
		line("UInt8Array[12]", () -> u[12]);
		line("UInt8Array[-5]", () -> u[-5]);
		var f = haxe.io.Float32Array.fromBytes(Bytes.alloc(16));
		line("Float32Array[3]", () -> f[3]);
		line("Float32Array[4]", () -> f[4]);
		line("Float32Array[MAX >> 2]", () -> f[MAX >> 2]);
		var i32 = haxe.io.Int32Array.fromBytes(Bytes.alloc(8));
		line("Int32Array[2]", () -> i32[2]);
		line("Int32Array set [2]", () -> i32[2] = 5);
	}
}
