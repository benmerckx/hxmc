// hxmc.MappedFile: a file's bytes mapped, byte for byte File.getBytes's,
// outside the heap (GcStats.liveBytes does not grow by them; on wasm32 they
// are read into it), through collections that move everything around them;
// writes reach the program's copy and never the file; sub, blit, compare,
// getString and the multi-byte accessors as on any Bytes, and their range
// tests too; the file deleted while mapped; a file of 64 KB (the smallest
// mapped), a small one (read), an empty one, a missing one; a FIFO, read
// from the descriptor opened (Linux and macOS: opening it twice lost what its
// writer wrote, and the second open waited for another).
import haxe.io.Bytes;
import hxmc.GcStats;
import hxmc.MappedFile;
import hxmc.NativeGc;
import sys.FileSystem;
import sys.io.File;

class Junk {
	public var next:Junk;
	public var v:Int;

	public function new(next:Junk, v:Int) {
		this.next = next;
		this.v = v;
	}
}

class MappedBytes {
	static inline var SIZE = 3 << 20;

	static var kept:Junk;

	static inline function at(i:Int):Int
		return (i * 131 + (i >> 9)) & 255;

	static function churn(n:Int) {
		var j:Junk = null;
		for (i in 0...n) {
			j = new Junk(i % 1000 == 0 ? null : j, i);
			if (i % 997 == 0) kept = new Junk(kept, i);
		}
	}

	static function outside(f:() -> Void):String {
		try {
			f();
			return "none";
		} catch (e:haxe.io.Error) {
			return Std.string(e);
		}
	}

	static function same(a:Bytes, b:Bytes):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length)
			if (a.get(i) != b.get(i)) return false;
		return true;
	}

	static function main() {
		var wasi = Sys.systemName() == "Wasi";
		var path = "mappedbytes.tmp", small = "mappedbytes-small.tmp", empty = "mappedbytes-empty.tmp", least = "mappedbytes-64k.tmp";
		var w = Bytes.alloc(SIZE);
		for (i in 0...SIZE)
			w.set(i, at(i));
		File.saveBytes(path, w);
		w = null;
		NativeGc.collect(true);
		var l0 = GcStats.liveBytes();
		var m = MappedFile.bytes(path);
		NativeGc.collect(true);
		Sys.println("outside the heap: " + (wasi || GcStats.liveBytes() - l0 < SIZE / 8));
		var g = File.getBytes(path);
		Sys.println(m.length + " " + same(m, g) + " " + m.compare(g) + " " + g.compare(m));
		churn(300000);
		NativeGc.collect(false);
		churn(300000);
		NativeGc.collect(true);
		Sys.println("after collections: " + same(m, g));
		Sys.println(m.getInt32(1000) == g.getInt32(1000) && m.getUInt16(SIZE - 2) == g.getUInt16(SIZE - 2) && m.getDouble(8) == g.getDouble(8)
			&& m.getFloat(SIZE - 4) == g.getFloat(SIZE - 4) && m.getInt64(SIZE - 8) == g.getInt64(SIZE - 8));
		Sys.println(m.getString(100, 7) == g.getString(100, 7) && m.toHex().substr(0, 32) == g.toHex().substr(0, 32));
		// sub: small (allocated with its Bytes), large, empty
		Sys.println(same(m.sub(5, 40), g.sub(5, 40)) + " " + same(m.sub(4096, 1 << 20), g.sub(4096, 1 << 20)) + " " + m.sub(SIZE, 0).length);
		Sys.println(Bytes.ofData(m.getData()).compare(g) == 0);
		// range tests, as an ordinary Bytes'
		Sys.println(outside(() -> m.get(SIZE)) + " " + outside(() -> m.get(-1)) + " " + outside(() -> m.set(SIZE, 1)));
		Sys.println(outside(() -> m.getInt32(SIZE - 3)) + " " + outside(() -> m.getDouble(SIZE - 7)) + " " + outside(() -> m.getUInt16(SIZE - 1))
			+ " " + outside(() -> m.setInt64(SIZE - 7, 0)));
		Sys.println(outside(() -> m.sub(SIZE - 1, 2)) + " " + outside(() -> m.blit(SIZE - 1, g, 0, 2)) + " " + outside(() -> g.blit(0, m, SIZE - 1, 2))
			+ " " + outside(() -> m.fill(-1, 2, 0)) + " " + outside(() -> m.getString(SIZE - 1, 2)));
		Sys.println(outside(() -> m.get(SIZE - 1)) + " " + outside(() -> m.getInt32(SIZE - 4)));
		// writes: the program's copy changes, the file does not
		m.set(0, 7);
		m.setInt32(4096, 0x12345678);
		m.fill(SIZE - 100, 100, 9);
		m.blit(1 << 20, g, 0, 5000);
		m.blit(10, m, 20, 30);
		Sys.println(m.get(0) + " " + StringTools.hex(m.getInt32(4096)) + " " + m.get(SIZE - 1) + " " + same(m.sub(1 << 20, 5000), g.sub(0, 5000))
			+ " " + (m.get(10) == at(20)));
		var again = MappedFile.bytes(path);
		Sys.println("file unchanged: " + (File.getBytes(path).compare(g) == 0) + " " + (again.compare(g) == 0));
		g.blit(0, m, 0, 16);
		Sys.println(g.get(0) + " " + again.get(0));
		// the smallest file mapped, a small file, an empty one, a missing one
		var b64 = Bytes.alloc(64 << 10);
		for (i in 0...b64.length)
			b64.set(i, at(i * 3));
		File.saveBytes(least, b64);
		Sys.println(MappedFile.bytes(least).compare(b64) == 0);
		FileSystem.deleteFile(least);
		File.saveContent(small, "héllo");
		var s = MappedFile.bytes(small);
		Sys.println(s.length + " " + s.toString() + " " + outside(() -> s.get(6)));
		File.saveContent(empty, "");
		Sys.println(MappedFile.bytes(empty).length);
		FileSystem.deleteFile(empty);
		FileSystem.deleteFile(small);
		try {
			MappedFile.bytes(small);
		} catch (e:String) {
			Sys.println(e);
		}
		var system = Sys.systemName();
		if (system != "Windows" && system != "Wasi") {
			var fifo = "mappedbytes.fifo";
			if (FileSystem.exists(fifo)) FileSystem.deleteFile(fifo);
			Sys.command("mkfifo", [fifo]);
			Sys.command("sh", ["-c", "echo through a pipe > " + fifo + " &"]);
			Sys.print(MappedFile.bytes(fifo).toString());
			FileSystem.deleteFile(fifo);
		} else
			Sys.println("through a pipe");
		FileSystem.deleteFile(path);
		NativeGc.collect(true);
		Sys.println("deleted: " + (m.get(0) == 7 && m.get(12345) == at(12345) && again.get(SIZE - 1) == at(SIZE - 1)));
	}
}
