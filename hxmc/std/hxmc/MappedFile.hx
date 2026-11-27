package hxmc;

// A file's bytes as a haxe.io.Bytes backed by a memory mapping instead of a
// copy in the heap (docs/using.md, "Mapped files"): only the pages read
// become resident, clean and file-backed, outside GcStats.liveBytes. The
// mapping is private and copy-on-write, so set, blit and fill behave as on
// any Bytes and never write the file (a page written becomes the program's
// own memory). It is never unmapped: getData() hands out the storage, which
// the collector does not follow outside its heap, so nothing tells when it
// is unreachable. Read into the heap instead (as File.getBytes): on
// WebAssembly, in macro code, in a program with compressed references
// (@:hxmc.compact), and for anything but a regular file under 2 GB that is
// not empty.
class MappedFile {
	public static function bytes(path:String):haxe.io.Bytes {
		#if macro
		return sys.io.File.getBytes(path);
		#else
		var b = NativeSys.fileMap(path);
		if (b == null) throw "Could not read file " + path;
		return b;
		#end
	}
}
