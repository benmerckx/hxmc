package core;

import core.ClassPath.ClassPathScope;

enum SourceScopeKind {
	User;
	Std;
	Lib(name:Null<String>);
	Path(path:String);
	Pack(pack:Array<String>);
}

class SourceScopeInvalid {
	public final msg:String;

	public function new(msg:String) this.msg = msg;
}

class SourceScopeUnknownKind {
	public function new() {}
}

// port: from haxe/src/core/sourceScope.ml; its type `t` is SourceScopeKind,
// its exceptions `Invalid` and `Unknown_kind` SourceScopeInvalid and SourceScopeUnknownKind.
class SourceScope {
	public static final expected = "Expected user, std, lib, lib:name, path:path or pack:dot.path";

	public static function isModuleName(s:String):Bool {
		if (s == "") return false;
		var c = StringTools.fastCodeAt(s, 0);
		return c >= "A".code && c <= "Z".code;
	}

	public static function isIdent(c:Int):Bool {
		return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;
	}

	public static function parseDotPath(v:String):Array<String> {
		// port: ExtString.String.nsplit ("" has no parts)
		var parts = v == "" ? [] : v.split(".");
		for (i in 0...parts.length) {
			var part = parts[i];
			var allIdent = true;
			for (j in 0...part.length) if (!isIdent(StringTools.fastCodeAt(part, j))) {
				allIdent = false;
				break;
			}
			if (part == "" || !allIdent) throw new SourceScopeInvalid("Invalid dot path: " + v);
			if (isModuleName(part) && i < parts.length - 1) throw new SourceScopeInvalid("Sub-types can't be selected, use the module or package path");
		}
		return parts;
	}

	public static function make(kind:String, value:Null<String>):SourceScopeKind {
		function required():String {
			if (value == "") throw new SourceScopeInvalid('Expected a value after $kind:');
			if (value != null) return value;
			throw new SourceScopeInvalid('Expected $kind:value');
		}
		return switch [kind, value] {
			case ["user", null]: SourceScopeKind.User;
			case ["std", null]: SourceScopeKind.Std;
			case ["lib", null]: SourceScopeKind.Lib(null);
			case ["lib", _]: SourceScopeKind.Lib(required());
			case ["path", _]: SourceScopeKind.Path(required());
			case ["pack", _]: SourceScopeKind.Pack(parseDotPath(required()));
			case _: throw new SourceScopeUnknownKind();
		}
	}

	public static function parse(s:String):SourceScopeKind {
		var i = s.indexOf(":");
		return i >= 0 ? make(s.substr(0, i), s.substr(i + 1)) : make(s, null);
	}

	public static function matchesPackage(pack:Array<String>, filePack:Null<Array<String>>):Bool {
		// port: the recursion over both lists, by index
		var i = 0;
		while (true) {
			if (i == pack.length) return true;
			if (filePack == null) return false;
			var p = pack[i];
			if (pack.length - i == 1 && filePack.length - i == 1 && isModuleName(p)) return p == filePack[i];
			if (i < filePack.length && p == filePack[i]) {
				i++;
				continue;
			}
			return false;
		}
	}

	public static function matcher(classPaths:ClassPaths, file:String):SourceScopeKind->Bool {
		// port: the lazy values of upstream's matcher
		var scopeDone = false;
		var scope:Null<ClassPathScope> = null;
		var comparable:Null<String> = null;
		var packDone = false;
		var pack:Null<Array<String>> = null;
		return function(selector) {
			if (!scopeDone) {
				scope = classPaths.scopeOf(file);
				scopeDone = true;
			}
			return switch selector {
				case SourceScopeKind.User: scope != null && scope.match(ClassPathScope.User);
				case SourceScopeKind.Std: scope != null && scope.match(ClassPathScope.Std | ClassPathScope.StdTarget);
				case SourceScopeKind.Lib(null): scope != null && scope.match(ClassPathScope.Lib(_));
				case SourceScopeKind.Lib(name):
					switch scope {
						case null: false;
						case ClassPathScope.Lib(name2) if (name2 != null): ClassPath.sameLibName(name, name2);
						case _: false;
					}
				case SourceScopeKind.Path(path):
					var path = core.Path.comparablePath(path);
					if (comparable == null) comparable = core.Path.comparablePath(file);
					var file = comparable;
					file == path || StringTools.startsWith(file, core.Path.addTrailingSlash(path));
				case SourceScopeKind.Pack(pack2):
					if (!packDone) {
						pack = classPaths.packageOf(file);
						packDone = true;
					}
					matchesPackage(pack2, pack);
			}
		}
	}
}
