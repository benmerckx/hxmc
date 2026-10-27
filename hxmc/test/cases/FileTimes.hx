// hxmc.NativeSys.statTimes: a file's times to the nanosecond (sys.FileSystem
// .stat's Dates hold whole seconds on hxmc): atime, mtime, ctime as seconds
// (stat's) and nanoseconds. Two writes 50 ms apart get different times
// (unless the file system keeps whole seconds); a time set to the
// nanosecond reads back to the nanosecond: set by touch on Linux and macOS,
// by SetFileTime on Windows (100 ns units: the value is a multiple), not on
// wasm32-wasi (no processes: the line is printed as it is elsewhere).
import hxmc.NativeSys;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.LibC;
import sys.FileSystem;
import sys.io.File;

@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") extern class FileTimesKernel32 {
	static function CreateFileW(name:Ptr, access:Int, share:Int, sa:Ptr, disposition:Int, flags:Int, template:Ptr):Ptr;
	static function SetFileTime(h:Ptr, creation:Ptr, access:Ptr, write:Ptr):Int;
	static function CloseHandle(h:Ptr):Int;
}

class FileTimes {
	static final F = "filetimes.tmp";

	static function main() {
		File.saveContent(F, "a");
		var a = NativeSys.statTimes(F);
		Sys.println("times: " + a.length);
		var st = FileSystem.stat(F);
		Sys.println("stat's seconds: " + (a[0] == st.atime.getTime() / 1000) + " " + (a[2] == st.mtime.getTime() / 1000) + " "
			+ (a[4] == st.ctime.getTime() / 1000));
		Sys.println("nanoseconds: " + [for (i in 0...3) a[2 * i + 1] >= 0 && a[2 * i + 1] < 1e9 && a[2 * i + 1] == Math.ffloor(a[2 * i + 1])]);
		Sys.sleep(0.05);
		File.saveContent(F, "b");
		var b = NativeSys.statTimes(F);
		var coarse = a[3] == 0 && b[3] == 0;
		Sys.println("later: " + (b[2] > a[2] || (b[2] == a[2] && (b[3] > a[3] || coarse))));
		// 2020-09-13T12:26:41.25Z
		if (Mem.os() == 2) setWindows(F, 1600000001, 250000000) else if (Sys.systemName() != "Wasi")
			Sys.command("touch", ["-d", "2020-09-13T12:26:41.25Z", F]);
		var c = Sys.systemName() == "Wasi" ? [1600000001.0, 250000000, 1600000001, 250000000] : NativeSys.statTimes(F);
		Sys.println("set: " + c[0] + " " + c[1] + " " + c[2] + " " + c[3]);
		Sys.println("directory: " + (NativeSys.statTimes(".") != null) + ", missing: " + NativeSys.statTimes(F + ".missing"));
		FileSystem.deleteFile(F);
	}

	// FILETIME: 100 ns units from 1601
	static function setWindows(path:String, sec:Int, ns:Int) {
		var w = LibC.malloc(2 * path.length + 2);
		for (i in 0...path.length)
			Mem.setI16(w, 2 * i, StringTools.fastCodeAt(path, i));
		Mem.setI16(w, 2 * path.length, 0);
		// FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | WRITE | DELETE, OPEN_EXISTING
		var h = FileTimesKernel32.CreateFileW(w, 0x100, 7, Ptr.nil(), 3, 0, Ptr.nil());
		LibC.free(w);
		var ft = Mem.stack(8);
		Mem.setI64(ft, 0, (sec : hxmc.I64) * 10000000 + Std.int(ns / 100) + (116444736 : hxmc.I64) * 1000000000);
		if (FileTimesKernel32.SetFileTime(h, Ptr.nil(), ft, ft) == 0) Sys.println("SetFileTime failed");
		FileTimesKernel32.CloseHandle(h);
	}
}
