// A define whose value is not UTF-8 (from build.hxml), inlined by
// Compiler.getDefine: its bytes reach the typed AST and the output.
class Main {
	static function main() {
		Sys.println(haxe.macro.Compiler.getDefine("bytes"));
	}
}
