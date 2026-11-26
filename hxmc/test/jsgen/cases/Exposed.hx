// @:expose, and what `-D dts` declares of it (`<output>.d.ts`, the es-dts variant: checked with tsc where JsGenCheck has
// one): an exposed class (its public API, its unexposed ancestor's, properties as JavaScript has them, `readonly` where
// only the class writes), an exposed static function and variable, under a path and at the top level
// dts has: declare namespace lib.shapes {
// dts has: class Circle {
// dts has: constructor(r: number);
// dts has: area(): number;
// dts has: readonly radius: number;
// dts has: readonly id: string;
// dts has: label: string;
// dts has: readonly kind: string;
// dts has: describe(): string;
// dts has: static unit(): lib.shapes.Circle;
// dts has: declare function makeCircle(r: number): lib.shapes.Circle;
// dts has: let version: string;
// dts lacks: get_kind
// dts lacks: secret
class Shape {
	public final id:String;
	public var label(get, set):String;
	public var kind(get, never):String;

	var name = "shape";

	public function new(id:String) {
		this.id = id;
	}

	function get_label() return name;

	function set_label(v:String) return name = v;

	function get_kind() return "shape";

	public function describe() return kind + " " + label;
}

@:expose("lib.shapes.Circle")
class Circle extends Shape {
	public var radius(default, null):Float;

	var secret = 42;

	public function new(r:Float) {
		super("c" + r);
		radius = r;
	}

	public function area() return Math.PI * radius * radius;

	public static function unit() return new Circle(1);

	@:expose("makeCircle") static function make(r:Float) return new Circle(r);

	@:expose("lib.version") static var version = "1.0";
}

class Exposed {
	static function main() {
		var c = Circle.unit();
		c.label = "one";
		trace(c.describe(), c.id, c.radius, c.area() > 3);
	}
}
