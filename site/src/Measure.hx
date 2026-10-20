import sys.FileSystem;
import sys.io.File;

using StringTools;

typedef Measured = {target:String, program:String, size:Int, seconds:Float};

// The hxmc page's sizes and build times, measured by the site's build:
// three programs (hello world, gfx's cube, ui's todo list) built for every
// target, each with an empty cache (a cold build: the std and the packages
// typed and compiled too), one at a time, on the machine that builds the
// site
class Measure {
	public static final TARGETS = [
		"linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64", "windows-arm64", "wasm32-wasi"
	];

	public static final PROGRAMS = [
		{name: "Hello world", main: "Hello", pkg: null, note: "Sys.println, the runtime and its collector"},
		{name: "Cube", main: "Cube", pkg: "gfx", note: "@hxmc/os and @hxmc/gfx: a window, the GPU, shaders"},
		{name: "Todo", main: "Todo", pkg: "ui", note: "@hxmc/ui: layout, text, widgets, markup"},
	];

	public static function run():Array<Measured> {
		var dir = Site.build + "/measure";
		var cache = dir + "/cache";
		FileSystem.createDirectory(dir);
		File.saveContent(dir + "/Hello.hx", "class Hello {\n\tstatic function main() {\n\t\tSys.println(\"Hello, world\");\n\t}\n}\n");
		var out = [];
		var t0 = haxe.Timer.stamp();
		for (p in PROGRAMS)
			for (t in TARGETS) {
				rm(cache);
				var exe = '$dir/${p.main}-$t' + (t.startsWith("windows") ? ".exe" : "");
				var args = p.pkg != null ? Examples.buildArgs(p.pkg, p.main, t, exe) : [
					exe, "-cp", dir, "-main", p.main, "-cp", "bin/hxmc/std", "--custom-target", "hxmc", "-D", 'hxmc.target=$t'
				];
				var s = haxe.Timer.stamp();
				var code = Site.sh([Site.tool].concat(args), exe + ".log", ["HXMC_CACHE" => cache]);
				var seconds = haxe.Timer.stamp() - s;
				if (code != 0 || !FileSystem.exists(exe)) throw 'site: ${p.main} for $t did not build';
				out.push({target: t, program: p.name, size: FileSystem.stat(exe).size, seconds: seconds});
			}
		rm(dir);
		Sys.println('site: ${out.length} builds measured in ${Math.round(haxe.Timer.stamp() - t0)} s');
		return out;
	}

	static function rm(path:String) {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (n in FileSystem.readDirectory(path))
				rm(path + "/" + n);
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}
}
