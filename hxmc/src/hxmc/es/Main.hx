package hxmc.es;

// the port's command line with hxmc's JavaScript generator (JsGen), for
// working on the generator without hxmc's native targets (make jsgen:
// bin/jsgen/haxe). As HaxeMain gives other targets hxmc-portable, it gives
// the program hxmc/portable (js.Bundle) of the checkout it was built in, when
// there; and the checkout's std unless HAXE_STD_PATH is set.
class Main {
	static function main() {
		JsGen.install();
		core.ds.GcPolicy.init();
		var args = Sys.args();
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		var root = haxe.io.Path.directory(haxe.io.Path.directory(haxe.io.Path.directory(exe)));
		if (Sys.getEnv("HAXE_STD_PATH") == null && sys.FileSystem.exists(root + "/haxe/upstream/std"))
			Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		var server = args.contains("--wait") || args.contains("--server-listen");
		if (!server && sys.FileSystem.exists(root + "/hxmc/portable")) args = ["-cp", root + "/hxmc/portable"].concat(args);
		Sys.exit(haxe.Main.run(args));
	}
}
