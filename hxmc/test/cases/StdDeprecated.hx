// Std.is and Std.instance, deprecated but still used by libraries: the same
// as Std.isOfType and Std.downcast.
class Base {
	public function new() {}
}

class Derived extends Base {}

class StdDeprecated {
	static function main() {
		var s:Dynamic = "s";
		Sys.println([Std.is(s, String), Std.is(s, Int), Std.is(null, String), Std.is(new Derived(), Base)]);
		var b:Base = new Derived();
		Sys.println([Std.instance(b, Derived) == b, Std.instance(new Base(), Derived) == null]);
	}
}
