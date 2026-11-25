package hxmc;

// -D esm on the Js platform: Genesm and optional std classpath (phase 1).
class EsmInstall {
	static var installed = false;

	public static function install():Void {
		if (installed) return;
		installed = true;
		generators.EsmHook.generate = function(com) {
			if (core.Define.rawDefined(com.defines, "esm.hot")) hxmc.genesm.GenesmHot.generate(com);
			else hxmc.genesm.Genesm.generate(com);
		};
		Defines.addEsmDefine();
		hxmc.esm.EsmHotInstall.install();
	}

	public static function selectsEsm(args:Array<String>, depth:Int):Bool {
		for (i in 0...args.length) {
			var a = args[i];
			if ((a == "-D" || a == "--define") && i + 1 < args.length) {
				var n = hxmc.HaxeMain.defineName(args[i + 1]).split("=")[0];
				if (n == "esm" || n == "esm.hot" || n == "esm.prod") return true;
			}
			if (StringTools.endsWith(a, ".hxml") && depth < 8 && sys.FileSystem.exists(a)) {
				var words = [];
				for (line in sys.io.File.getContent(a).split("\n")) {
					line = StringTools.trim(line);
					if (line == "" || StringTools.startsWith(line, "#")) continue;
					var sp = line.indexOf(" ");
					if (sp < 0) words.push(line) else {
						words.push(line.substr(0, sp));
						words.push(StringTools.trim(line.substr(sp + 1)));
					}
				}
				if (selectsEsm(words, depth + 1)) return true;
			}
		}
		return false;
	}

	public static function esmStdPath():Null<String> {
		var boot = Sys.getEnv("HXMC_STD");
		if (boot != null && sys.FileSystem.exists(boot + "/../esm-std")) return haxe.io.Path.normalize(boot + "/../esm-std");
		var src = haxe.io.Path.normalize("hxmc/std/esm");
		return sys.FileSystem.exists(src) ? src : null;
	}
}
