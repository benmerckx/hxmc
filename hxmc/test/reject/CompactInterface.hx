// @:hxmc.compact is about an object's fields: an interface has none.
// expect: Shape is an interface: @:hxmc.compact is for classes
@:hxmc.compact
interface Shape {
	function area():Float;
}

class Square implements Shape {
	public function new() {}

	public function area()
		return 1.0;
}

class CompactInterface {
	static function main() {
		var s:Shape = new Square();
		trace(s.area());
	}
}
