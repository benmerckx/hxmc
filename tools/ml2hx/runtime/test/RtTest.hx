import ml2hx.rt.*;
import ml2hx.std.*;

// The runtime's tests: `rttest <name>` prints what tools/ml2hx/runtime/test/<name>.ml
// prints under OCaml (<name>.expected).
class RtTest {
	public static var dir = "tools/ml2hx/runtime/test";

	static function main() {
		var args = Sys.args();
		if (args.length > 1) dir = args[1];
		var name = args.length > 0 ? args[0] : "";
		var tests:haxe.ds.StringMap<Void->Void> = [
			"smoke" => () -> {
				ml2hx.std.Stdlib.printEndline("hello " + ml2hx.std.Stdlib.stringOfFloat(1.5));
			},
		];
		var t = tests.get(name);
		if (t == null) {
			Sys.stderr().writeString("unknown test " + name + "\n");
			Sys.exit(2);
		}
		t();
		ml2hx.std.Stdlib.doAtExit();
	}
}
