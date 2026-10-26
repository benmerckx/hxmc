// Core dumps (docs/hxmc.md, "Core dumps"): the runtime reserves tens of GB
// of address space (the old space's two regions, the nursery, the stacks),
// and a core dump holds a reserved mapping whole once a page of it is
// touched, its untouched pages as zeros. Through a pipe (systemd-coredump,
// apport) the core of a crash was 36 GB and took minutes (NullAccessCrash
// ran into CI's timeout, #43). On Linux the runtime leaves out of a core
// dump what it does not use of its reservations: the mappings a core would
// hold, read from /proc/self/smaps (those with anonymous pages, not marked
// "dd"), stay under 1 GB here, after major collections (the old space moved
// to its other region and back). Without /proc/self/smaps (macOS,
// WebAssembly), or with qemu-user's (it makes one up, every Rss 0, and
// does not apply MADV_DONTDUMP), the line is the same.
import hxmc.NativeGc;

class CoreDumpSize {
	static function main() {
		var keep = [];
		for (i in 0...300000) {
			keep.push("s" + i);
			if (i % 100000 == 0) NativeGc.collect(true);
		}
		NativeGc.collect(true);
		Sys.println("kept " + keep.length);
		var bytes = dumped();
		Sys.println("a core dump under 1 GB: " + (bytes < 1024.0 * 1024 * 1024));
		if (bytes >= 1024.0 * 1024 * 1024) Sys.println(Std.int(bytes / (1 << 20)) + " MB");
	}

	static function hex(s:String):Float {
		var v = 0.0;
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			v = v * 16 + (c <= "9".code ? c - "0".code : c - "a".code + 10);
		}
		return v;
	}

	// the bytes a core dump through a pipe would carry
	static function dumped():Float {
		var f = "/proc/self/smaps";
		if (!sys.FileSystem.exists(f)) return 0;
		var head = ~/^([0-9a-f]+)-([0-9a-f]+) /;
		var total = 0.0, size = 0.0, anon = false, rss = false;
		for (l in sys.io.File.getContent(f).split("\n")) {
			if (head.match(l)) {
				size = hex(head.matched(2)) - hex(head.matched(1));
				anon = false;
			} else if (StringTools.startsWith(l, "Rss:")) {
				if (Std.parseInt(StringTools.trim(l.substr(4)).split(" ")[0]) > 0) rss = true;
			} else if (StringTools.startsWith(l, "Anonymous:")) {
				anon = Std.parseInt(StringTools.trim(l.substr(10)).split(" ")[0]) > 0;
			} else if (StringTools.startsWith(l, "VmFlags:")) {
				if (anon && l.indexOf(" dd") < 0) total += size;
			}
		}
		return rss ? total : 0;
	}
}
