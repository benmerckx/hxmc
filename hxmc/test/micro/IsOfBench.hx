// Std.isOfType(v, C), Std.downcast(v, C) and cast(v, C) with a class
// literal, over an array of instances of a small hierarchy and nulls, the
// time per test. Not a corpus case (times vary); built and run by hand:
//   bin/hxmc/hxmc -cp hxmc/test/micro -main IsOfBench -cp bin/hxmc/std --custom-target hxmc=bin/isofbench
//   bin/isofbench [ops] [kind]      (default 20000000 tests per row, every kind)
// kind: is (Std.isOfType of a typed value), isdyn (of a Dynamic one),
// downcast, cast (a checked cast of the hits).
// For instruction counts, one row under callgrind minus the same row with 0
// tests: `bin/isofbench 1000000 <kind>`. x86-64, instructions per test with
// the loop, before FnLower.instClass (hx_is: Dyn.isOf, classExtends; cast:
// hx_cast) -> after (EInstOf, a range of type indices):
//   is 109 -> 50, isdyn 107 -> 51, downcast 110 -> 52, cast 73 -> 50
class IsOfBench {
	static function main() {
		var args = Sys.args();
		var ops = args.length > 0 ? Std.parseInt(args[0]) : 20000000;
		var kinds = args.length > 1 ? [args[1]] : ["is", "isdyn", "downcast", "cast"];
		var vs:Array<Base> = [];
		for (i in 0...64)
			vs.push(switch i % 5 {
				case 0: new Base();
				case 1: new Mid();
				case 2: new Leaf();
				case 3: new Other();
				case _: null;
			});
		var ds:Array<Dynamic> = [for (v in vs) v];
		for (k in kinds) {
			var n = 0;
			var t0 = Sys.time();
			switch k {
				case "is":
					for (i in 0...ops)
						if (Std.isOfType(vs[i & 63], Mid)) n++;
				case "isdyn":
					for (i in 0...ops)
						if (Std.isOfType(ds[i & 63], Mid)) n++;
				case "downcast":
					for (i in 0...ops) {
						var m = Std.downcast(vs[i & 63], Mid);
						if (m != null) n += m.x;
					}
				case "cast":
					for (i in 0...ops) {
						var v = vs[i & 63];
						if (v != null && v.x > 0) n += cast(v, Mid).x;
					}
				case _:
					throw "kind: is, isdyn, downcast, cast";
			}
			var dt = Sys.time() - t0;
			Sys.println(k + ": " + Math.round(dt * 1e9 / ops * 100) / 100 + " ns/test (" + n + ")");
		}
	}
}

class Base {
	public var x = 0;

	public function new() {}
}

class Mid extends Base {
	public function new() {
		super();
		x = 1;
	}
}

class Leaf extends Mid {}
class Other extends Base {}
