package lazies;

// (its module imports its subclass's: a cycle, which the split imports the super class's module first of)
class Shape {
	public function new() {}

	public function name() return "shape";

	public static function make():Shape return new Circle();
}
