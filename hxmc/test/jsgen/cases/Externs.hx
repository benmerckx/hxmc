// externs of node modules (@:jsRequire), a module and an object in one: required in a
// single file, imported in modules
@:jsRequire("node:path")
extern class NodePath {
	static function join(a:String, b:String):String;
}

@:jsRequire("node:path", "posix")
extern class Posix {
	static function basename(p:String):String;
}

class Externs {
	static function main() {
		trace(NodePath.join("a", "b"));
		js.Bundle.split("later", () -> Posix.basename("/x/y.txt")).then(v -> trace(v));
	}
}
