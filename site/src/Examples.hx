import hxmc.web.Static;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

using StringTools;

// What a demo is: a program on a canvas (wasm32-wasi), a sound started by a
// click, a JavaScript island, or a module JavaScript calls
enum DemoKind {
	Canvas(width:Int, height:Int);
	Sound;
	JsIsland;
	Module;
}

typedef Example = {
	// "gfx-cube": the package and the file's name
	id:String,
	pkg:String,
	main:String,
	file:String,
	title:String,
	summary:String,
	tags:Array<String>,
	demo:DemoKind,
	// the files shown: the example and the files of its folder it uses
	sources:Array<String>,
	// (a WebAssembly build: its file in the site, its size, gzipped)
	?wasm:String,
	?size:Int,
	?gz:Int,
}

// The examples gallery's examples: each package's examples/ folder, every
// file with a header naming it,
//
//   // title: Cube
//   // summary: A textured cube casting a soft shadow, its shaders in Haxe
//   // tags: gfx, shaders, 3d
//   // demo: canvas 512x384
//
// (demo: canvas WxH, a program drawing on a canvas; sound, a program
// started by a click; island, a JavaScript island of @hxmc/web; module, a
// wasm module JavaScript calls). Each wasm32-wasi one is built by the site
// with the package's class paths and shown with the imports of the
// packages it uses.
class Examples {
	public static final PACKAGES = ["gfx", "3d", "physics", "ui", "os", "text", "view", "web"];

	// each package's class paths (its dependencies' first) and the browser
	// modules its programs need
	public static function classPaths(pkg:String):Array<String> {
		return switch pkg {
			case "os": ["-cp", "packages/os/src"];
			case "gfx": ["-cp", "packages/os/src", "-cp", "packages/gfx/src"];
			case "3d": ["-cp", "packages/os/src", "-cp", "packages/gfx/src", "-cp", "packages/text/src", "-cp", "packages/ui/src", "-cp", "packages/3d/src"];
			case "physics": ["-cp", "packages/os/src", "-cp", "packages/gfx/src", "-cp", "packages/3d/src", "-cp", "packages/physics/src"];
			case "text": ["-cp", "packages/os/src", "-cp", "packages/gfx/src", "-cp", "packages/text/src"];
			case "ui": [
					"-cp", "packages/os/src", "-cp", "packages/gfx/src", "-cp", "packages/text/src", "-cp", "packages/view/src",
					"-D", "hxmc.view.renderer.ui=hxmc.ui.view.NodeRenderer", "-cp", "packages/ui/src", "-cp", "packages/theme/src"
				];
			case "web": ["-cp", "packages/web/src"];
			case _: [];
		}
	}

	public static function imports(pkg:String):Array<String> {
		return switch pkg {
			case "os": ["os/imports.mjs"];
			case "gfx" | "3d" | "physics": ["os/imports.mjs", "gfx/imports.mjs"];
			case "text": ["os/imports.mjs", "gfx/imports.mjs", "text/imports.mjs"];
			case "ui": ["os/imports.mjs", "gfx/imports.mjs", "text/imports.mjs", "ui/imports.mjs"];
			case "web": ["web/imports.mjs"];
			case _: [];
		}
	}

	// the fonts a program of the package may use (a browser gives none)
	public static function fonts(pkg:String):Null<Array<String>>
		return pkg == "ui" || pkg == "text" ? ["fonts/DejaVuSans.ttf", "fonts/DejaVuSans-Bold.ttf"] : null;

	static final FONT_DIRS = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/TTF", "/usr/share/fonts/dejavu", "/Library/Fonts"];

	static final HEADER = ~/^\/\/ *(title|summary|tags|demo): *(.*)$/;

	public static function collect():Array<Example> {
		var out = [];
		for (pkg in PACKAGES) {
			var dir = 'packages/$pkg/examples';
			if (!FileSystem.exists(dir)) continue;
			var names = FileSystem.readDirectory(dir).filter(n -> n.endsWith(".hx"));
			names.sort(Reflect.compare);
			for (n in names) {
				var file = '$dir/$n';
				var head = new Map<String, String>();
				for (line in File.getContent(file).split("\n")) {
					if (!line.startsWith("//")) break;
					if (HEADER.match(line.trim())) head.set(HEADER.matched(1), HEADER.matched(2).trim());
				}
				if (!head.exists("title")) continue;
				var main = n.substr(0, n.length - 3);
				var demo = parseDemo(head.get("demo"), file);
				var siblings = [for (m in names) if (m != n) m.substr(0, m.length - 3)];
				out.push({
					id: pkg + "-" + main.toLowerCase(),
					pkg: pkg,
					main: main,
					file: file,
					title: head.get("title"),
					summary: head.exists("summary") ? head.get("summary") : "",
					tags: head.exists("tags") ? [for (t in head.get("tags").split(",")) t.trim()] : [pkg],
					demo: demo,
					sources: [file].concat(used(file, dir, siblings)),
				});
			}
		}
		// (the order of the gallery: graphics first, the web's last)
		return out;
	}

	static function parseDemo(s:Null<String>, file:String):DemoKind {
		if (s == null) throw '$file: no demo: line';
		var size = ~/^canvas +(\d+)x(\d+)$/;
		if (size.match(s)) return Canvas(Std.parseInt(size.matched(1)), Std.parseInt(size.matched(2)));
		return switch s {
			case "sound": Sound;
			case "island": JsIsland;
			case "module": Module;
			case _: throw '$file: demo: $s?';
		}
	}

	// the files of the folder an example names (CubeShader for Cube), and theirs
	static function used(file:String, dir:String, siblings:Array<String>):Array<String> {
		var found = [];
		var todo = [file];
		while (todo.length > 0) {
			var src = File.getContent(todo.shift());
			for (s in siblings) {
				var f = '$dir/$s.hx';
				if (found.contains(f) || f == file) continue;
				if (new EReg("\\b" + s + "\\b", "").match(src)) {
					found.push(f);
					todo.push(f);
				}
			}
		}
		return found;
	}

	// a file's size gzipped (gzip -9: what a server sends, about)
	public static function gzipped(file:String):Null<Int> {
		var p = new Process("sh", ["-c", "gzip -9c " + Site.quote(file) + " | wc -c"]);
		var n = Std.parseInt(StringTools.trim(p.stdout.readAll().toString()));
		p.close();
		return n;
	}

	// each wasm32-wasi example built (in parallel, jobs at a time), into the site's examples/
	public static function buildAll(examples:Array<Example>) {
		var todo = [for (e in examples) if (e.demo.match(Canvas(_, _) | Sound | Module)) e];
		var running:Array<{e:Example, p:Process, out:String}> = [];
		var failed = [];
		var t0 = haxe.Timer.stamp();
		FileSystem.createDirectory(Site.build + "/examples");
		function finish(r:{e:Example, p:Process, out:String}) {
			var code = r.p.exitCode();
			r.p.close();
			if (code != 0 || !FileSystem.exists(r.out)) {
				Sys.println(File.getContent(r.out + ".log"));
				failed.push(r.e.id);
				return;
			}
			var to = 'examples/${r.e.id}.wasm';
			Static.copy(r.out, Site.out + "/" + to);
			r.e.wasm = to;
			r.e.size = FileSystem.stat(r.out).size;
			r.e.gz = gzipped(r.out);
		}
		while (todo.length > 0 || running.length > 0) {
			while (todo.length > 0 && running.length < Site.jobs) {
				var e = todo.shift();
				var o = '${Site.build}/examples/${e.id}.wasm';
				var args = [o].concat(classPaths(e.pkg)).concat([
					"-cp", 'packages/${e.pkg}/examples', "-main", e.main, "-cp", "bin/hxmc/std", "--custom-target", "hxmc", "-D", "hxmc.target=wasm32-wasi",
					// (legacy exception handling: every browser with WebGPU has it, those with WebGL2 since 2021)
					"-D", "hxmc.wasm-eh=legacy"
				]);
				// (the output in a log: a pipe nobody reads would fill)
				var cmd = [Site.tool].concat(args).map(Site.quote).join(" ") + " > " + Site.quote(o + ".log") + " 2>&1";
				running.push({e: e, p: new Process("sh", ["-c", "ulimit -s unlimited 2>/dev/null; " + cmd]), out: o});
			}
			// (the oldest first: the builds take about as long)
			finish(running.shift());
		}
		if (failed.length > 0) throw 'site: examples failed to build: ${failed.join(", ")}';
		Sys.println('site: ${examples.length} examples built in ${Math.round(haxe.Timer.stamp() - t0)} s');
		// the fonts the ui and text programs are given
		if (Lambda.exists(examples, e -> fonts(e.pkg) != null)) {
			for (f in ["DejaVuSans.ttf", "DejaVuSans-Bold.ttf"]) {
				var src = Lambda.find(FONT_DIRS, d -> FileSystem.exists('$d/$f'));
				if (src == null) throw 'site: $f not found (install fonts-dejavu-core) in ${FONT_DIRS.join(", ")}';
				Static.copy('$src/$f', '${Site.out}/fonts/$f');
			}
		}
	}
}
