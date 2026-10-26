package hxmc;

// A rebuild from the same archive: the executable is a function of the
// archive, the arguments and the tool, so when none changed since the last
// build it is up to date and nothing runs (not even the port's loading of
// the archive). The archive is identified by its ZIP central directory: the
// name, CRC-32 and size of every member, read without inflating anything.
class UpToDate {
	// the key of this build, or null when there is no archive to identify
	public static function key(args:Array<String>, out:String):Null<String> {
		var i = args.indexOf("--hxb-lib");
		if (i < 0 || i + 1 >= args.length) return null;
		var dir = zipDirectory(args[i + 1]);
		if (dir == null) return null;
		var p = Sys.programPath();
		var st = try sys.FileSystem.stat(p) catch (_:Dynamic) null;
		var tool = st == null ? "?" : st.size + "@" + st.mtime.getTime();
		// and the runtime object it links
		var target = "linux-x86_64";
		for (a in args)
			if (StringTools.startsWith(a, "hxmc.target=")) target = a.substr(12);
		var rt = Sys.getEnv("HXMC_RT_OBJ");
		// (and the environment that changes the code: Options.framePointers)
		var fp = Sys.getEnv("HXMC_FRAME_POINTERS");
		if (fp != null) tool += "|fp=" + fp;
		if (rt == null) rt = Options.rtDir(target) + "rt.o";
		// (and the objects of sys.ssl and libuv next to it)
		for (p in [rt, haxe.io.Path.directory(rt) + "/ssl.o", haxe.io.Path.directory(rt) + "/uv.o"]) {
			var rs = try sys.FileSystem.stat(p) catch (_:Dynamic) null;
			tool += rs == null ? "|?" : "|" + rs.size + "@" + rs.mtime.getTime();
		}
		// (and the objects and archives -D hxmc.link names; record() adds those of @:hxmc.link)
		for (a in args)
			if (StringTools.startsWith(a, "hxmc.link="))
				for (p in a.substr(10).split(","))
					tool += "|" + stamp(StringTools.trim(p));
		return Fingerprint.hash(tool + "\n" + args.join("\x00") + "\n" + dir);
	}

	// (in the store: ObjectStore; else next to the output)
	static function keyFile(out:String):String {
		var s = ObjectStore.open(out);
		return s != null ? s.keyFile() : out + ".hxmc/build.key";
	}

	public static function check(key:Null<String>, out:String):Bool {
		if (key == null) return false;
		var exe = sys.FileSystem.exists(out) ? out : sys.FileSystem.exists(out + ".exe") ? out + ".exe" : null;
		if (exe == null || !sys.FileSystem.exists(keyFile(out))) return false;
		var lines = try sys.io.File.getContent(keyFile(out)).split("\n") catch (_:Dynamic) return false;
		if (lines[0] != key) return false;
		for (k in 1...lines.length) {
			var l = lines[k];
			if (l == "") continue;
			var tab = l.indexOf("\t");
			if (tab < 0 || stamp(l.substr(0, tab)) != l.substr(tab + 1)) return false;
		}
		return true;
	}

	static function stamp(p:String):String {
		var s = try sys.FileSystem.stat(p) catch (_:Dynamic) null;
		return s == null ? "?" : s.size + "@" + s.mtime.getTime();
	}

	public static function record(key:Null<String>, out:String) {
		if (key == null) return;
		var f = keyFile(out);
		var d = haxe.io.Path.directory(f);
		if (!sys.FileSystem.exists(d)) sys.FileSystem.createDirectory(d);
		var b = new StringBuf();
		b.add(key);
		for (p in hxmc.ir.CInterop.LINKS)
			b.add("\n" + p + "\t" + stamp(p));
		sys.io.File.saveContent(f, b.toString());
	}

	public static function forget(out:String) {
		if (sys.FileSystem.exists(keyFile(out))) sys.FileSystem.deleteFile(keyFile(out));
	}

	// "name crc size" per member, from the end-of-central-directory record
	static function zipDirectory(path:String):Null<String> {
		if (!sys.FileSystem.exists(path)) return null;
		var f = sys.io.File.read(path, true);
		try {
			var size = sys.FileSystem.stat(path).size;
			var tail = size < 65557 ? size : 65557;
			f.seek(size - tail, SeekBegin);
			var t = f.read(tail);
			var e = tail - 22;
			while (e >= 0 && !(t.get(e) == 0x50 && t.get(e + 1) == 0x4b && t.get(e + 2) == 5 && t.get(e + 3) == 6))
				e--;
			if (e < 0) {
				f.close();
				return null;
			}
			var cdSize = t.getInt32(e + 12), cdOff = t.getInt32(e + 16);
			f.seek(cdOff, SeekBegin);
			var cd = f.read(cdSize);
			f.close();
			var b = new StringBuf();
			var p = 0;
			while (p + 46 <= cdSize && cd.getInt32(p) == 0x02014b50) {
				var crc = cd.getInt32(p + 16), usize = cd.getInt32(p + 24);
				var n = cd.getUInt16(p + 28), x = cd.getUInt16(p + 30), c = cd.getUInt16(p + 32);
				b.add(cd.getString(p + 46, n));
				b.add(" ");
				b.add(crc);
				b.add(" ");
				b.add(usize);
				b.add("\n");
				p += 46 + n + x + c;
			}
			return b.toString();
		} catch (e:Dynamic) {
			f.close();
			return null;
		}
	}
}
