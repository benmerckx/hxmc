// build-seconds: 10
// A function of a thousand nested constructor calls over other statics
// (macros.Nest: the shape of ml2hx's generated tables). Each argument is
// live across every allocation after it: spilled and reloaded at each
// allocation's slow path, that is a million values and a minute of register
// allocation; rooted (Roots.MAX_COLD_SPILLS), a few thousand. The build
// must take less than build-seconds (Corpus).
enum BigList {
	Nil;
	Cons(h:Array<Int>, t:BigList);
}

@:build(macros.Nest.values())
class BigInitValues {}

class BigInit {
	static var table:BigList;

	static function main() {
		table = macros.Nest.table(1000);
		var n = 0, sum = 0;
		var l = table;
		while (true)
			switch l {
				case Cons(h, t):
					n++;
					sum += h[0];
					l = t;
				case Nil:
					break;
			}
		Sys.println(n + " " + sum);
	}
}
