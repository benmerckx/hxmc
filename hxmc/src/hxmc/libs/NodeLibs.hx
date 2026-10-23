package hxmc.libs;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// `-lib <name>` from node_modules (Libraries asks it after lix's scope and
// before haxelib; docs/using.md): the nearest node_modules, from the working
// directory up as node looks, holding a package whose package.json has a
// "haxe" field, {"name": "hxmc.gfx", "classPath": "src", "hxml":
// "extraParams.hxml"} ("hxml" optional), named <name> there (or <name> is
// the package's own name); `-lib <name>:<version>` takes it only at that
// version. A package expands as haxelib's output does: its hxml's lines, its
// class path (absolute), -D <name>=<version>, then its dependencies: the
// packages of its "dependencies" and "peerDependencies" (found from its
// directory, as node does) that have a "haxe" field, recursively; each
// package once per NodeLibs.
class NodeLibs {
	final cwd:String;
	final added = new Map<String, Bool>();
	// package.json of a package directory (null: none, or no "haxe" field)
	final pkgs = new Map<String, Null<Pkg>>();

	public function new(cwd:String) {
		this.cwd = Path.removeTrailingSlashes(Path.normalize(cwd));
	}

	// lib (haxelib's name[:version]) -> haxelib path's lines for it (empty:
	// added before), or null when node_modules does not have it
	public function resolve(lib:String):Null<Array<String>> {
		var colon = lib.indexOf(":");
		var name = colon < 0 ? lib : lib.substr(0, colon);
		var version = colon < 0 ? null : lib.substr(colon + 1);
		var pkg = find(name);
		if (pkg == null || (version != null && version != pkg.version)) return null;
		var lines = [];
		add(pkg, lines);
		return lines;
	}

	// a directory and its parents (normalized: "/" separators)
	static function dirs(from:String):Array<String> {
		var out = [], d = from;
		while (true) {
			out.push(d);
			var i = d.lastIndexOf("/");
			if (i < 0) break;
			// ("": the root, whose node_modules is "/node_modules")
			if (i == 0) {
				if (d != "") out.push("");
				break;
			}
			d = d.substr(0, i);
		}
		return out;
	}

	function pkg(dir:String):Null<Pkg> {
		if (pkgs.exists(dir)) return pkgs.get(dir);
		var p:Null<Pkg> = null;
		var text = try File.getContent('$dir/package.json') catch (_:Dynamic) null;
		if (text != null) {
			var json:Dynamic = try haxe.Json.parse(text) catch (e:Dynamic) throw new Scope.LibraryError('$dir/package.json: $e');
			var h:Dynamic = Reflect.field(json, "haxe");
			if (h != null) {
				var deps = [];
				for (f in ["dependencies", "peerDependencies"]) {
					var o:Dynamic = Reflect.field(json, f);
					if (o != null) for (k in Reflect.fields(o)) if (!deps.contains(k)) deps.push(k);
				}
				var str = (o:Dynamic, f:String) -> {
					var v:Dynamic = Reflect.field(o, f);
					v == null ? null : Std.string(v);
				}
				p = {
					dir: dir,
					pkgName: str(json, "name"),
					name: str(h, "name") ?? str(json, "name"),
					version: str(json, "version"),
					classPath: str(h, "classPath"),
					hxml: str(h, "hxml"),
					deps: deps
				};
			}
		}
		pkgs.set(dir, p);
		return p;
	}

	// the package named <name> in the nearest node_modules: likely directories
	// first (<name>, and @a/b for a.b), then every package there
	function find(name:String):Null<Pkg> {
		for (d in dirs(cwd)) {
			var nm = '$d/node_modules';
			if (!FileSystem.exists(nm) || !FileSystem.isDirectory(nm)) continue;
			var guesses = [name];
			var dot = name.indexOf(".");
			if (dot > 0) guesses.push("@" + name.substr(0, dot) + "/" + name.substr(dot + 1));
			for (g in guesses) {
				if (g.contains("..") || g.contains("\\")) continue;
				var p = pkg('$nm/$g');
				if (p != null && (p.name == name || p.pkgName == name)) return p;
			}
			for (e in sorted(nm)) {
				if (e.startsWith(".")) continue;
				var sub = e.startsWith("@") ? sorted('$nm/$e').map(s -> '$e/$s') : [e];
				for (s in sub) {
					var p = pkg('$nm/$s');
					if (p != null && (p.name == name || p.pkgName == name)) return p;
				}
			}
		}
		return null;
	}

	static function sorted(dir:String):Array<String> {
		var a = try FileSystem.readDirectory(dir) catch (_:Dynamic) [];
		a.sort((x, y) -> x < y ? -1 : x > y ? 1 : 0);
		return a;
	}

	// a dependency of the package in dir: node_modules/<dep> from dir up
	function dependency(dir:String, dep:String):Null<Pkg> {
		for (d in dirs(dir)) {
			if (Path.withoutDirectory(d) == "node_modules") continue;
			var p = pkg('$d/node_modules/$dep');
			if (p != null) return p;
		}
		return null;
	}

	function add(p:Pkg, lines:Array<String>) {
		if (added.exists(p.dir)) return;
		added.set(p.dir, true);
		if (p.hxml != null) {
			var file = Path.isAbsolute(p.hxml) ? p.hxml : '${p.dir}/${p.hxml}';
			var text = try File.getContent(file) catch (_:Dynamic) throw new Scope.LibraryError('${p.dir}/package.json: the hxml file $file is missing');
			for (l in text.split("\n")) {
				var l = l.trim();
				if (l != "" && !l.startsWith("#")) lines.push(l);
			}
		}
		var cp = p.classPath == null ? p.dir : Path.isAbsolute(p.classPath) ? p.classPath : '${p.dir}/${p.classPath}';
		lines.push(Path.addTrailingSlash(Path.normalize(cp)));
		lines.push("-D " + p.name + (p.version == null ? "" : "=" + p.version));
		for (dep in p.deps) {
			var d = dependency(p.dir, dep);
			if (d != null) add(d, lines);
		}
	}
}

private typedef Pkg = {
	dir:String,
	pkgName:Null<String>,
	name:String,
	version:Null<String>,
	classPath:Null<String>,
	hxml:Null<String>,
	deps:Array<String>
}
