// define: hxmc.paths=hxmc/test/cases=<cases>
// define: hxmc.native-array-outofbounds=throws
// With -D hxmc.paths, the program's strings name its sources by a label,
// not where they were built: a macro's string of a position (helder's live
// literals' ids are such), a switch over one (its case's hash the same
// string's), and the file of a check's error. Strings without the dir
// stay as they are.
import haxe.macro.Context;
import haxe.macro.Expr;

class SourcePaths {
	macro static function here():Expr
		return macro $v{Context.getPosInfos(Context.currentPos()).file + ":12:color"};

	static function main() {
		var id = here();
		Sys.println(id);
		Sys.println(switch id {
			case "<cases>/SourcePaths.hx:12:color": "switch: by its label";
			case _: "switch: " + id;
		});
		Sys.println("cases/SourcePaths.hx:12");
		var v = new haxe.ds.Vector<Int>(1);
		try {
			v[3] = 1;
		} catch (e:haxe.exceptions.ArgumentException) {
			Sys.println('error at ${e.posInfos.fileName}:${e.posInfos.lineNumber}');
		}
	}
}
