package lazies;

// (a split of a module that does not import lazies.Common, which the program has run: imported for its binding,
// beside the modules of the cycle, imported one after the other)
class Opener {
	public static function shapes() return js.Bundle.split("shapes", () -> Common.tag(Shape.make().name() + ", " + new Circle().name()));
}
