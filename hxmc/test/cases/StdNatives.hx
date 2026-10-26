// The std natives of the runtime (Array, Bytes, BytesBuffer, FPHelper,
// Date, DEFLATE and CRC-32, Math.random, reflection), beyond what the other
// cases reach. Times and time zones are not printed (they depend on the
// machine): only their consistency.
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.FPHelper;

class StdNatives {
	static function text():String {
		var b = new StringBuf();
		for (i in 0...20)
			b.add("The quick brown fox jumps over the lazy dog. ");
		b.add("hxmc runtime in Haxe 0123456789");
		return b.toString();
	}

	static function main() {
		// arrays of every element kind
		var ints = [5, 3, 9, 1, 7];
		ints.sort((a, b) -> a - b);
		var floats = [2.5, -1.0, 3.25];
		floats.sort((a, b) -> a < b ? 1 : a > b ? -1 : 0);
		var strs = ["pear", "apple", "fig"];
		strs.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		Sys.println(ints + " " + floats + " " + strs);
		var a = [1, 2, 3, 4, 5, 6];
		Sys.println(a.splice(1, 2) + " " + a + " " + a.slice(1, -1) + " " + a.slice(-2));
		a.insert(0, 10);
		a.insert(100, 20);
		a.insert(-1, 30);
		a.unshift(0);
		Sys.println(a + " " + a.indexOf(30) + " " + a.lastIndexOf(10) + " " + a.contains(4) + " " + a.remove(4) + " " + a);
		Sys.println(a.pop() + " " + a.shift() + " " + a + " " + a.copy().concat([7, 8]) + " " + a.join("-"));
		a.reverse();
		Sys.println(a + " " + a.filter(x -> x % 2 == 0) + " " + a.map(x -> "<" + x + ">"));
		var d:Array<Dynamic> = [1, "two", 3.5, null, [4]];
		Sys.println(d + " " + d.indexOf("two") + " " + d.indexOf(3.5) + " " + d.concat(floats));
		a.resize(2);
		Sys.println(a + " " + a.length);
		a.resize(4);
		Sys.println(a + " " + a.length);
		var big = [for (i in 0...100) (i * 37) % 101];
		big.sort(Reflect.compare);
		Sys.println(big.slice(0, 10) + " " + big[99]);
		// bytes
		var b = Bytes.alloc(16);
		b.fill(0, 16, 0);
		b.set(0, 0x41);
		b.setUInt16(2, 0xBEEF);
		b.setInt32(4, -123456);
		b.setFloat(8, 1.5);
		b.setDouble(8, 0.1);
		Sys.println(b.get(0) + " " + b.getUInt16(2) + " " + b.getInt32(4) + " " + b.getDouble(8) + " " + b.toHex());
		var c = b.sub(2, 6);
		Sys.println(c.toHex() + " " + c.length + " " + b.compare(c) + " " + c.compare(c));
		b.blit(10, c, 0, 6);
		Sys.println(b.toHex() + " " + Bytes.ofHex("48656c6c6f").toString());
		var u = Bytes.ofString("h\u00e9llo \u{1F600}");
		Sys.println(u.length + " " + u.toHex() + " " + u.getString(0, u.length) + " " + u.getString(1, 2));
		b.setFloat(0, 3.14159);
		Sys.println(Std.string(b.getFloat(0)).substr(0, 7));
		try {
			b.sub(10, 10);
		} catch (e:Dynamic) {
			Sys.println("sub: " + e);
		}
		var bb = new BytesBuffer();
		for (i in 0...100)
			bb.addByte(i);
		bb.addString("xyz");
		bb.addInt32(0x01020304);
		bb.addFloat(2.0);
		bb.addDouble(-0.5);
		bb.addBytes(Bytes.ofString("abcdef"), 1, 3);
		bb.add(Bytes.ofString("!"));
		var r = bb.getBytes();
		Sys.println(bb.length + " " + r.length + " " + r.sub(98, r.length - 98).toHex());
		// FPHelper
		Sys.println(FPHelper.floatToI32(1.0) + " " + FPHelper.i32ToFloat(0x40490FDB) + " " + FPHelper.doubleLow(1.0) + " " + FPHelper.doubleHigh(1.0) + " " + FPHelper.i64ToDouble(0, 0x3FF80000));
		// DEFLATE: stored, dynamic and fixed blocks; CRC-32
		var t = Bytes.ofString(text());
		var stored = new BytesBuffer();
		stored.addByte(1);
		stored.addByte(t.length & 255);
		stored.addByte(t.length >> 8);
		stored.addByte(~t.length & 255);
		stored.addByte((~t.length >> 8) & 255);
		stored.add(t);
		for (z in [stored.getBytes(), Bytes.ofHex("edcadb1940200006d055fe097cee970d0cd002240a1529627a86f0d8f3398433ec4ed005bdd197c2a83d6627b703fa6406f6e3b57b6e0c7a8a40420e39e4bf33f792c238658564100a6de719e224cdf2a2aceae605"), Bytes.ofHex("0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb29848c2a1e553caa98da8a332a7293158a4af34a3273531532f3143c122b52150c0c8d8c4d4ccdcc2d2c01")]) {
			var out = Bytes.alloc(t.length + 10);
			var n = hxmc.NativeZip.inflateRaw(z, 0, z.length, out, 0, out.length);
			Sys.println(z.length + " -> " + n + " " + (n == t.length && out.sub(0, n).compare(t) == 0));
		}
		var small = Bytes.alloc(10);
		Sys.println("too small: " + hxmc.NativeZip.inflateRaw(Bytes.ofHex("edcadb1940200006d055fe097cee970d0cd002240a1529627a86f0d8f3398433ec4ed005bdd197c2a83d6627b703fa6406f6e3b57b6e0c7a8a40420e39e4bf33f792c238658564100a6de719e224cdf2a2aceae605"), 0, 85, small, 0, 10) + " garbage: " + hxmc.NativeZip.inflateRaw(Bytes.ofHex("ffffffff"), 0, 4, small, 0, 10));
		Sys.println("crc " + hxmc.NativeZip.crc32(t, 0, t.length) + " " + hxmc.NativeZip.crc32(t, 4, 0) + " " + haxe.crypto.Crc32.make(t));
		// dates (consistency only)
		var d1 = new Date(2020, 1, 29, 13, 45, 30);
		Sys.println(d1.getFullYear() + " " + d1.getMonth() + " " + d1.getDate() + " " + d1.getDay() + " " + d1.getHours() + " " + d1.getMinutes() + " " + d1.getSeconds() + " " + d1.toString());
		var d2 = Date.fromTime(d1.getTime());
		Sys.println(d2.toString() == d1.toString() && d2.getTime() == d1.getTime());
		var d3 = Date.fromString("2001-09-09 01:46:40");
		Sys.println(d3.toString() + " " + Date.fromString("1999-12-31").toString() + " " + Date.fromString("12:34:56").getTime());
		var tz = d1.getTimezoneOffset();
		var utcMinutes = d1.getHours() * 60 + d1.getMinutes() + tz;
		Sys.println((Std.int((utcMinutes + 1440) / 60) % 24 == d1.getUTCHours()) + " " + ((utcMinutes + 1440) % 60 == d1.getUTCMinutes()) + " " + d1.getUTCSeconds());
		// (in summer: daylight saving where the zone has it)
		var d4 = new Date(2020, 6, 15, 13, 45, 30);
		var utc4 = d4.getHours() * 60 + d4.getMinutes() + d4.getTimezoneOffset();
		Sys.println((Std.int((utc4 + 1440) / 60) % 24 == d4.getUTCHours()) + " " + ((utc4 + 1440) % 60 == d4.getUTCMinutes()) + " " + d4.getUTCSeconds());
		var now = Date.now();
		Sys.println(now.getFullYear() >= 2024 && now.getTime() > d1.getTime());
		try {
			Date.fromString("nonsense");
		} catch (e:Dynamic) {
			Sys.println(e);
		}
		var rs = [for (i in 0...1000) Math.random()];
		Sys.println(Lambda.foreach(rs, x -> x >= 0 && x < 1) + " " + Lambda.exists(rs, x -> x > 0.5) + " " + (Std.random(10) < 10));
		// reflection and Dynamic
		var o:Dynamic = {b: 2, a: "x", c: [1, 2]};
		o.d = 4.5;
		Reflect.setField(o, "e", true);
		var fs = Reflect.fields(o);
		fs.sort((x, y) -> x < y ? -1 : 1);
		Sys.println(fs + " " + Reflect.field(o, "a") + " " + o.d + " " + Reflect.hasField(o, "e") + " " + Reflect.deleteField(o, "e") + " " + Reflect.hasField(o, "e"));
		var s:Dynamic = "hello";
		Sys.println(s.length + " " + s.charAt(1) + " " + s.toUpperCase() + " " + s.indexOf("l") + " " + s.split("l"));
		var arr:Dynamic = [3, 1, 2];
		arr.push(0);
		Sys.println(arr.length + " " + arr.join("+") + " " + arr.indexOf(2) + " " + Reflect.callMethod(null, (p:Int, q:Int) -> p * q, [3, 9]));
		Sys.println(Type.typeof(1) + " " + Type.typeof(1.5) + " " + Type.typeof("s"));
		Sys.println(Type.typeof(null) + " " + Type.typeof(o));
		Sys.println(Type.getClassName(Type.getClass("s")) + " " + Type.getClass(b));
		var x:Dynamic = 7, y:Dynamic = 2.5;
		Sys.println((x + y) + " " + (x * y) + " " + (x / 2) + " " + (x % 3) + " " + (x << 2) + " " + (x + "s") + " " + (x == 7.0) + " " + (y > x));
	}
}
