// splits of modules (es-modules: `import()`s of the modules their code needs, as a bundler finds them): of
// classes of other modules, one of which extends another module's class, of a cycle (lazies.Shape and lazies.Circle:
// imported one after the other, the super class's first; lazies.Opener: beside a module the program has run)
import lazies.Panel;
import lazies.Common;

class Lazies {
	static function main() {
		var n = 2;
		trace(Common.tag("main"));
		js.Bundle.split("panel", () -> Panel.render(n)).then(s -> {
			trace(s);
			return lazies.Opener.shapes();
		}).then(s -> trace(s));
	}
}
