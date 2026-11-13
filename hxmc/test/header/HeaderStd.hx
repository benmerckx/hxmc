// What the header check compiles hxmc's own typed bindings for (make
// header-check): a program reaching the std's system calls, its time,
// sleep, files and sockets.
class HeaderStd {
	static function main() {
		trace(Sys.time() > 0, Sys.cpuTime() >= 0);
		Sys.sleep(0.001);
		var f = sys.io.File.write("bin/header-std.txt");
		f.writeString("x");
		f.close();
		var i = sys.io.File.read("bin/header-std.txt");
		trace(i.readAll().length, i.tell());
		i.close();
		var s = new sys.net.Socket();
		s.setBlocking(false);
		s.setFastSend(true);
		s.setTimeout(1.5);
		try s.bind(new sys.net.Host("127.0.0.1"), 0) catch (_:Dynamic) {}
		s.close();
		Sys.putEnv("HXMC_HEADER", "1");
		trace(Sys.getEnv("HXMC_HEADER"));
		sys.FileSystem.rename("bin/header-std.txt", "bin/header-std2.txt");
		sys.FileSystem.deleteFile("bin/header-std2.txt");
		sys.FileSystem.createDirectory("bin/header-std.d");
		sys.FileSystem.deleteDirectory("bin/header-std.d");
		Sys.setCwd(Sys.getCwd());
	}
}
