package hxmc.libs;

import compiler.HighLevel;
import core.ds.ArgumentError;
import hxmc.libs.Scope;

// -lib in the npm package's compiler (hxmc.HaxeMain installs it as
// compiler.HighLevel's libraryResolver and haxelibHook; docs/using.md), per
// part (--next): within lix's scope (Scope: a .haxerc), as lix's haxe shim
// resolves a build's libraries, each once: haxe_libraries/<name>.hxml,
// node_modules (NodeLibs), haxelib after the part's arguments; without one,
// as before: per group of -lib, node_modules, then haxelib through the
// compiler's add_libs. haxelib is answered without a process (Haxelib).
class Libraries {
	// inheritScope: HAXESHIM_SCOPE applies (the shim drops it for a leading --cwd)
	public static function install(inheritScope:Bool) {
		HighLevel.libraryResolver = () -> new Libraries(inheritScope);
		HighLevel.haxelibHook = args -> Haxelib.run(args, Sys.getCwd(), Sys.getEnv);
	}

	final inheritScope:Bool;
	// by working directory: its scope (null: none)
	final scopes = new Map<String, Null<Scope>>();
	// by .haxerc: the part's build in that scope; in order
	final builds = new Map<String, Build>();
	final order:Array<Build> = [];
	// by working directory, in a scope: node_modules' packages, each once per part
	final nodes = new Map<String, NodeLibs>();

	function new(inheritScope:Bool) {
		this.inheritScope = inheritScope;
	}

	public function expand(libs:Array<String>, cwd:String):{args:Array<String>, rest:Array<String>} {
		return try {
			if (!scopes.exists(cwd)) scopes[cwd] = Scope.seek(cwd, Sys.getEnv, inheritScope);
			switch scopes[cwd] {
				case null:
					var node = new NodeLibs(cwd), lines = [], rest = [];
					for (lib in libs) switch node.resolve(lib) {
						case null: rest.push(lib);
						case found: for (l in found) lines.push(l);
					}
					{args: HighLevel.libArgs(lines), rest: rest};
				case scope:
					var b = builds[scope.configFile];
					if (b == null) {
						builds[scope.configFile] = b = scope.build();
						order.push(b);
					}
					var node = nodes[cwd];
					if (node == null) nodes[cwd] = node = new NodeLibs(cwd);
					{args: b.expand(libs, cwd, lib -> switch node.resolve(lib) {
						case null: null;
						case found: HighLevel.libArgs(found);
					}), rest: []};
			}
		} catch (e:LibraryError) throw new ArgumentError(e.message);
	}

	public function finish():Array<String> {
		var out = [];
		try for (b in order) out = out.concat(b.finish()) catch (e:LibraryError) throw new ArgumentError(e.message);
		return out;
	}
}
