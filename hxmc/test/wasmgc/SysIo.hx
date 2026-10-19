// what the port needs beyond the language (GcCheck): file streams (written,
// appended, updated, read, sought, told), Sys.command, processes, FPHelper's bit
// patterns, the atomics, hxmc.NativeZip's inflate and CRC-32
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

class SysIo {
	static function main() {
		var dir = "bin/wasmgc/sysio";
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		var path = dir + "/f.txt";
		// written, appended, read back
		var o = File.write(path, true);
		o.writeString("first line\n");
		o.writeInt32(0x41424344);
		o.writeString("\nsecond\n");
		Sys.println("tell " + o.tell());
		o.close();
		var a = File.append(path, true);
		a.writeString("appended\n");
		a.close();
		var i = File.read(path, true);
		Sys.println(i.readLine() + "|" + i.readInt32() + "|" + i.readLine() + "|" + i.readLine() + "|" + i.readLine());
		try {
			i.readLine();
		} catch (e:haxe.io.Eof) {
			Sys.println("eof " + i.eof());
		}
		i.seek(6, SeekBegin);
		Sys.println("sought " + i.readString(4) + " " + i.tell());
		i.seek(-9, SeekEnd);
		Sys.println("from the end " + i.readLine());
		i.close();
		// updated in place
		var u = File.update(path, true);
		u.seek(0, SeekBegin);
		u.writeString("FIRST");
		u.close();
		Sys.println(File.getContent(path).split("\n")[0] + " " + FileSystem.stat(path).size);
		// a file that cannot be opened
		try {
			File.read(dir + "/missing.txt");
		} catch (e:Dynamic) {
			Sys.println("not opened: " + e);
		}
		FileSystem.deleteFile(path);
		// through the shell
		Sys.println("command " + Sys.command("exit 3"));
		// processes: their output and errors, input, a command that cannot run
		var p = new sys.io.Process("sh", ["-c", "echo out; echo err >&2; exit 4"]);
		Sys.println(p.stdout.readAll().toString() + p.stderr.readAll().toString() + p.exitCode());
		p.close();
		var cat = new sys.io.Process("cat");
		cat.stdin.writeString("piped through\n");
		cat.stdin.close();
		Sys.println(cat.stdout.readLine() + " " + cat.exitCode());
		var none = new sys.io.Process("hxmc-no-such-command", []);
		Sys.println("[" + none.stdout.readAll().toString() + "] " + none.exitCode());
		// FPHelper
		var bits = haxe.io.FPHelper.doubleToI64(1.5);
		Sys.println(bits.high + " " + bits.low + " " + haxe.io.FPHelper.i64ToDouble(0, 0x40090000) + " " + haxe.io.FPHelper.floatToI32(0.1) + " "
			+ haxe.io.FPHelper.i32ToFloat(0x3E800000) + " " + haxe.io.FPHelper.doubleToI64(-0.0).high);
		// atomics
		var n = new haxe.atomic.AtomicInt(5);
		Sys.println(n.add(3) + " " + n.sub(1) + " " + n.and(6) + " " + n.or(9) + " " + n.xor(3) + " " + n.compareExchange(12, 1) + " "
			+ n.compareExchange(5, 2) + " " + n.exchange(7) + " " + n.load() + " " + n.store(4) + " " + n.load());
		var x = {v: 1}, y = {v: 2};
		var ao = new haxe.atomic.AtomicObject(x);
		Sys.println(ao.load().v + " " + ao.compareExchange(y, y).v + " " + ao.compareExchange(x, y).v + " " + ao.exchange(x).v + " " + ao.load().v);
		// inflate: fixed, dynamic and stored blocks, then the errors
		for (hex in [
			"cb48cdc9c957c84022c3138b73dd9d01",
			"9d955b72c2400c04ff730a1d0169cdc3b94d1e8600c64e4c0824a7a7c88e0ed0fe76759556d31af7fba1b3c5b37d7f74f675d9bf1ded751aaf836dc79b1d2ea7cfb38d3fddf4ffb97ff9fbb5f771678ba7fe4139a3bc52c1a8a65285516da51a38e1aa624b866d2ab56254546a0d475c566c03b152b1761ee650909cd2a122da89434714804349326e879a482e879ac864879ee86c1c8a92374a45110645d1db027aa24d066d120517f33c09e889ac0cda263a82809ee4d1051525b999951250955c0b544521145a29cabc4057a45899f9dba195220caaa2632dd4146150947c1bf42437491b2583c39edc01",
			"010c00f3ff73746f726564206279746573"
		]) {
			var src = Bytes.ofHex(hex);
			var dst = Bytes.alloc(4096);
			var len = hxmc.NativeZip.inflateRaw(src, 0, src.length, dst, 2, 4000);
			var text = dst.sub(2, len).toString();
			Sys.println(len + " " + hxmc.NativeZip.crc32(dst, 2, len) + " " + text.substr(0, 24).split("\n").join("/") + " "
				+ hxmc.NativeZip.inflateRaw(src, 0, src.length - 1, dst, 0, 4000) + " " + hxmc.NativeZip.inflateRaw(src, 0, src.length, dst, 0, len - 1));
		}
	}
}
