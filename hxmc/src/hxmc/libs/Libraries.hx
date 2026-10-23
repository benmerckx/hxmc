package hxmc.libs;

import compiler.HighLevel;
import core.ds.ArgumentError;
import hxmc.libs.Scope;

// -lib in the npm package's compiler (hxmc.HaxeMain installs it as
// compiler.HighLevel's libraryResolver and context.Common's haxelibHook;
// docs/using.md), per part (--next): within lix's scope (Scope: a .haxerc),
// as lix's haxe shim resolves a build's libraries, each once:
// haxe_libraries/<name>.hxml, node_modules (NodeLibs), haxelib after the
// part's arguments; without one, as before: per group of -lib, node_modules,
// then haxelib through the compiler's add_libs. The `haxelib` the compiler
// asks (add_libs, the cpp generator's `haxelib path hxcpp`) is answered
// without a process: lix's haxelib shim within a scope, haxelib outside
// (Scope.haxelib).
class Libraries {
	// inheritScope: HAXESHIM_SCOPE applies (the shim drops it for a leading --cwd)
	public static function install(inheritScope:Bool) {
		HighLevel.libraryResolver = () -> new Libraries(inheritScope);
		context.Common.haxelibHook = args -> Scope.haxelib(args, Sys.getCwd(), Sys.getEnv, inheritScope, dir -> {
			var node = new NodeLibs(dir);
			lib -> switch node.resolve(lib) {
				case null: null;
				case found: HighLevel.libArgs(found);
			}
		});
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
					{args: neko(b.expand(libs, cwd, lib -> switch node.resolve(lib) {
						case null: null;
						case found: HighLevel.libArgs(found);
					})), rest: []};
			}
		} catch (e:LibraryError) throw new ArgumentError(e.message);
	}

	public function finish():Array<String> {
		var out = [];
		try for (b in order) out = out.concat(neko(b.finish())) catch (e:LibraryError) throw new ArgumentError(e.message);
		return out;
	}

	// a build's -lib ndll:<dir>, as the compiler gets it from the shim's haxelib (-L <dir>)
	static function neko(args:Array<String>):Array<String> {
		var out = [], i = 0;
		while (i < args.length)
			if (args[i] == "-lib" && i + 1 < args.length && StringTools.startsWith(args[i + 1], "ndll:")) {
				out.push("--neko-lib-path");
				out.push(args[i + 1].substr(5));
				i += 2;
			} else out.push(args[i++]);
		return out;
	}
}
